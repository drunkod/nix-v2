{
  description = "A V2Ray server and client flake with optional WARP egress";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        v2rayPackage = pkgs.v2ray;

        serverConfig = ./v2ray-server-config.json;
        clientConfig = ./v2ray-client-config.json;
        serverWarpConfig = ./v2ray-server-config-warp.json;

        localClientConfig = pkgs.runCommand "v2ray-local-client-config.json" {
          nativeBuildInputs = [ pkgs.jq ];
        } ''
          jq '
            (.outbounds[] | select(.protocol == "vmess") | .settings.vnext[0].address) = "127.0.0.1"
            | (.outbounds[] | select(.protocol == "vmess") | .streamSettings.wsSettings.headers.Host) = "127.0.0.1"
          ' ${clientConfig} > "$out"
        '';

        mkV2RayRunner = { name, config, messages ? [ ] }:
          pkgs.writeShellScriptBin name ''
            set -euo pipefail
            ${pkgs.lib.concatMapStringsSep "\n" (message:
              "echo ${pkgs.lib.escapeShellArg message}"
            ) messages}
            exec ${v2rayPackage}/bin/v2ray run -config ${config}
          '';

        mkApp = package: binary: {
          type = "app";
          program = "${package}/bin/${binary}";
        };

        warpConfigShell = ''
          warp_dir="''${WARP_DIR:-$PWD/warp}"
          wireproxy_config="$warp_dir/wireproxy.conf"
        '';

        requireWarpConfigShell = ''
          ${warpConfigShell}
          if [ ! -f "$wireproxy_config" ]; then
            echo "Error: $wireproxy_config not found. Run 'nix run .#warp-setup' first."
            echo "Set WARP_DIR to use a different state directory."
            exit 1
          fi
        '';

        portToolsShell = ''
          show_port_owners() {
            local port="$1"
            ${pkgs.iproute2}/bin/ss -ltnp "sport = :$port" || true
            ${pkgs.iproute2}/bin/ss -lunp "sport = :$port" || true
          }

          require_free_port() {
            local port="$1"
            if {
              ${pkgs.iproute2}/bin/ss -H -ltn "sport = :$port" || true
              ${pkgs.iproute2}/bin/ss -H -lun "sport = :$port" || true
            } | ${pkgs.gnugrep}/bin/grep -q .; then
              echo "Error: port $port is already in use. Stop the old process before starting this stack."
              show_port_owners "$port"
              return 1
            fi
          }

          wait_for_port() {
            local pid="$1"
            local process_name="$2"
            local port="$3"

            for ((attempt = 1; attempt <= 40; attempt++)); do
              if ! kill -0 "$pid" 2>/dev/null; then
                echo "Error: $process_name exited before port $port became ready."
                wait "$pid" 2>/dev/null || true
                return 1
              fi

              if {
                ${pkgs.iproute2}/bin/ss -H -ltn "sport = :$port" || true
                ${pkgs.iproute2}/bin/ss -H -lun "sport = :$port" || true
              } | ${pkgs.gnugrep}/bin/grep -q .; then
                return 0
              fi

              ${pkgs.coreutils}/bin/sleep 0.25
            done

            echo "Error: $process_name did not open port $port within 10 seconds."
            return 1
          }
        '';
      in
      {
        packages = rec {
          v2ray-server = mkV2RayRunner {
            name = "run-v2ray-server";
            config = serverConfig;
            messages = [
              "Starting V2Ray server with config: ${serverConfig}"
              "Make sure port 8080 is open and the client points to this machine."
            ];
          };

          v2ray-client = mkV2RayRunner {
            name = "run-v2ray-client";
            config = clientConfig;
            messages = [
              "Starting V2Ray client with config: ${clientConfig}"
              "SOCKS5 proxy will be available on 127.0.0.1:10808."
            ];
          };

          v2ray-client-local = mkV2RayRunner {
            name = "run-v2ray-client-local";
            config = localClientConfig;
            messages = [
              "Starting local VPS client against 127.0.0.1:8080."
              "SOCKS5 proxy will be available on 127.0.0.1:10808."
            ];
          };

          v2ray = v2rayPackage;

          warp-setup = pkgs.writeShellScriptBin "warp-setup" ''
            set -euo pipefail
            umask 077

            warp_dir="''${WARP_DIR:-$PWD/warp}"
            mkdir -p "$warp_dir"
            warp_dir="$(cd "$warp_dir" && pwd -P)"

            account_config="$warp_dir/wgcf-account.toml"
            profile_config="$warp_dir/wgcf-profile.conf"
            wireproxy_config="$warp_dir/wireproxy.conf"

            cd "$warp_dir"

            if [ ! -f "$account_config" ]; then
              echo "Registering WARP account..."
              ${pkgs.wgcf}/bin/wgcf register --accept-tos
            else
              echo "WARP account already exists, skipping registration."
            fi

            if [ ! -f "$profile_config" ]; then
              echo "Generating WireGuard profile..."
              ${pkgs.wgcf}/bin/wgcf generate
            else
              echo "WireGuard profile already exists, skipping generation."
            fi

            echo "Generating wireproxy config..."
            {
              cat "$profile_config"
              printf '\n[Socks5]\nBindAddress = 127.0.0.1:40000\n'
            } > "$wireproxy_config"
            chmod 600 "$account_config" "$profile_config" "$wireproxy_config"

            echo "WARP files prepared in $warp_dir"
            echo "Next: run 'nix run .#warp-proxy' then 'nix run .#server-warp'."
          '';

          warp-proxy = pkgs.writeShellScriptBin "warp-proxy" ''
            set -euo pipefail
            ${requireWarpConfigShell}

            echo "Starting wireproxy with $wireproxy_config (SOCKS5 on 127.0.0.1:40000)..."
            exec ${pkgs.wireproxy}/bin/wireproxy -c "$wireproxy_config"
          '';

          v2ray-server-warp = mkV2RayRunner {
            name = "run-v2ray-server-warp";
            config = serverWarpConfig;
            messages = [
              "Starting V2Ray server with WARP egress config: ${serverWarpConfig}"
              "Ensure wireproxy is running with 'nix run .#warp-proxy'."
            ];
          };

          v2ray-server-warp-all = pkgs.writeShellScriptBin "run-v2ray-server-warp-all" ''
            set -euo pipefail
            ${requireWarpConfigShell}
            ${portToolsShell}

            require_free_port 40000
            require_free_port 8080

            WIREPROXY_PID=""
            V2RAY_PID=""

            cleanup() {
              local status=$?
              trap - EXIT INT TERM

              for pid in "$V2RAY_PID" "$WIREPROXY_PID"; do
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                  kill "$pid" 2>/dev/null || true
                fi
              done

              for pid in "$V2RAY_PID" "$WIREPROXY_PID"; do
                if [ -n "$pid" ]; then
                  wait "$pid" 2>/dev/null || true
                fi
              done

              exit "$status"
            }

            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            echo "Starting wireproxy with $wireproxy_config..."
            ${pkgs.wireproxy}/bin/wireproxy -c "$wireproxy_config" &
            WIREPROXY_PID=$!
            wait_for_port "$WIREPROXY_PID" "wireproxy" 40000

            echo "Starting V2Ray server with WARP egress..."
            ${v2rayPackage}/bin/v2ray run -config ${serverWarpConfig} &
            V2RAY_PID=$!
            wait_for_port "$V2RAY_PID" "V2Ray server" 8080

            set +e
            wait -n "$WIREPROXY_PID" "$V2RAY_PID"
            status=$?
            set -e

            if ! kill -0 "$WIREPROXY_PID" 2>/dev/null; then
              echo "wireproxy stopped; shutting down V2Ray."
            elif ! kill -0 "$V2RAY_PID" 2>/dev/null; then
              echo "V2Ray stopped; shutting down wireproxy."
            fi

            exit "$status"
          '';

          v2ray-stack = pkgs.writeShellScriptBin "run-v2ray-stack" ''
            set -euo pipefail
            ${requireWarpConfigShell}
            ${portToolsShell}

            require_free_port 10808

            SERVER_STACK_PID=""
            CLIENT_PID=""

            cleanup() {
              local status=$?
              trap - EXIT INT TERM

              for pid in "$CLIENT_PID" "$SERVER_STACK_PID"; do
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                  kill "$pid" 2>/dev/null || true
                fi
              done

              for pid in "$CLIENT_PID" "$SERVER_STACK_PID"; do
                if [ -n "$pid" ]; then
                  wait "$pid" 2>/dev/null || true
                fi
              done

              exit "$status"
            }

            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            echo "Starting supervised WARP server stack..."
            ${v2ray-server-warp-all}/bin/run-v2ray-server-warp-all &
            SERVER_STACK_PID=$!
            wait_for_port "$SERVER_STACK_PID" "WARP server stack" 8080

            echo "Starting local V2Ray client..."
            ${v2ray-client-local}/bin/run-v2ray-client-local &
            CLIENT_PID=$!
            wait_for_port "$CLIENT_PID" "V2Ray client" 10808

            echo "All services are ready: wireproxy=:40000, server=:8080, client=:10808"

            set +e
            wait -n "$SERVER_STACK_PID" "$CLIENT_PID"
            status=$?
            set -e

            if ! kill -0 "$SERVER_STACK_PID" 2>/dev/null; then
              echo "WARP server stack stopped; shutting down the local client."
            elif ! kill -0 "$CLIENT_PID" 2>/dev/null; then
              echo "Local V2Ray client stopped; shutting down the WARP server stack."
            fi

            exit "$status"
          '';

          vps-install = pkgs.writeShellScriptBin "install-v2ray-warp-systemd" ''
            set -euo pipefail

            if [ "$(id -u)" -ne 0 ]; then
              echo "Error: run this installer as root."
              exit 1
            fi

            if ! command -v systemctl >/dev/null 2>&1; then
              echo "Error: systemctl is not available on this VPS."
              exit 1
            fi

            state_dir="''${WARP_DIR:-/var/lib/nix-v2ray-warp}"
            profile="/nix/var/nix/profiles/nix-v2ray-warp"
            unit_name="nix-v2ray-warp.service"
            unit_path="/etc/systemd/system/$unit_name"

            mkdir -p "$state_dir"
            chmod 700 "$state_dir"

            if [ ! -f "$state_dir/wireproxy.conf" ]; then
              echo "Error: $state_dir/wireproxy.conf does not exist."
              echo "Prepare it first with:"
              echo "  WARP_DIR=$state_dir nix --extra-experimental-features 'nix-command flakes' run .#warp-setup"
              exit 1
            fi

            systemctl stop "$unit_name" >/dev/null 2>&1 || true

            ${portToolsShell}
            require_free_port 40000
            require_free_port 8080
            require_free_port 10808

            echo "Installing the supervised stack into the persistent Nix profile $profile..."
            ${pkgs.nix}/bin/nix-env -p "$profile" -i ${v2ray-stack}

            cat > "$unit_path" <<UNIT
[Unit]
Description=V2Ray server, local client and Cloudflare WARP proxy
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$state_dir
Environment="WARP_DIR=$state_dir"
ExecStart=$profile/bin/run-v2ray-stack
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=20
UMask=0077
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

            chmod 644 "$unit_path"
            systemctl daemon-reload
            systemctl enable "$unit_name"
            systemctl restart "$unit_name"

            echo "Installed and started $unit_name"
            echo "Status: systemctl status $unit_name"
            echo "Logs:   journalctl -u $unit_name -f"
          '';

          default = v2ray-server;
        };

        apps = rec {
          server = mkApp self.packages.${system}.v2ray-server "run-v2ray-server";
          client = mkApp self.packages.${system}.v2ray-client "run-v2ray-client";
          client-local = mkApp self.packages.${system}.v2ray-client-local "run-v2ray-client-local";
          warp-setup = mkApp self.packages.${system}.warp-setup "warp-setup";
          warp-proxy = mkApp self.packages.${system}.warp-proxy "warp-proxy";
          server-warp = mkApp self.packages.${system}.v2ray-server-warp "run-v2ray-server-warp";
          server-warp-all = mkApp self.packages.${system}.v2ray-server-warp-all "run-v2ray-server-warp-all";
          stack = mkApp self.packages.${system}.v2ray-stack "run-v2ray-stack";
          vps-install = mkApp self.packages.${system}.vps-install "install-v2ray-warp-systemd";
          default = server;
        };

        checks.config-json = pkgs.runCommand "validate-v2ray-json" {
          nativeBuildInputs = [ pkgs.jq ];
        } ''
          jq empty ${serverConfig}
          jq empty ${clientConfig}
          jq empty ${localClientConfig}
          jq empty ${serverWarpConfig}
          touch "$out"
        '';

        devShells.default = pkgs.mkShell {
          name = "v2ray-dev-shell";
          packages = [
            v2rayPackage
            pkgs.curl
            pkgs.iproute2
            pkgs.jq
            pkgs.wgcf
            pkgs.wireproxy
          ];
          shellHook = ''
            echo "V2Ray dev shell: v2ray, wgcf, wireproxy, curl, iproute2 and jq are available."
            echo "Server config: ${serverConfig}"
            echo "Client config: ${clientConfig}"
            echo "Local client:  ${localClientConfig}"
            echo "WARP config:   ${serverWarpConfig}"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
