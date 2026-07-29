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

            WIREPROXY_PID=""
            V2RAY_PID=""

            cleanup() {
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
            }

            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM

            echo "Starting wireproxy with $wireproxy_config..."
            ${pkgs.wireproxy}/bin/wireproxy -c "$wireproxy_config" &
            WIREPROXY_PID=$!

            ready=false
            for ((attempt = 1; attempt <= 20; attempt++)); do
              if ! kill -0 "$WIREPROXY_PID" 2>/dev/null; then
                echo "Error: wireproxy exited before its SOCKS5 listener became ready."
                wait "$WIREPROXY_PID" || true
                exit 1
              fi

              if (echo > /dev/tcp/127.0.0.1/40000) >/dev/null 2>&1; then
                ready=true
                break
              fi

              ${pkgs.coreutils}/bin/sleep 0.25
            done

            if [ "$ready" != "true" ]; then
              echo "Error: wireproxy did not open 127.0.0.1:40000 in time."
              exit 1
            fi

            echo "Starting V2Ray server with WARP egress..."
            ${v2rayPackage}/bin/v2ray run -config ${serverWarpConfig} &
            V2RAY_PID=$!

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

          default = v2ray-server;
        };

        apps = rec {
          server = mkApp self.packages.${system}.v2ray-server "run-v2ray-server";
          client = mkApp self.packages.${system}.v2ray-client "run-v2ray-client";
          warp-setup = mkApp self.packages.${system}.warp-setup "warp-setup";
          warp-proxy = mkApp self.packages.${system}.warp-proxy "warp-proxy";
          server-warp = mkApp self.packages.${system}.v2ray-server-warp "run-v2ray-server-warp";
          server-warp-all = mkApp self.packages.${system}.v2ray-server-warp-all "run-v2ray-server-warp-all";
          default = server;
        };

        checks.config-json = pkgs.runCommand "validate-v2ray-json" {
          nativeBuildInputs = [ pkgs.jq ];
        } ''
          jq empty ${serverConfig}
          jq empty ${clientConfig}
          jq empty ${serverWarpConfig}
          touch "$out"
        '';

        devShells.default = pkgs.mkShell {
          name = "v2ray-dev-shell";
          packages = [
            v2rayPackage
            pkgs.curl
            pkgs.jq
            pkgs.wgcf
            pkgs.wireproxy
          ];
          shellHook = ''
            echo "V2Ray dev shell: v2ray, wgcf, wireproxy, curl and jq are available."
            echo "Server config: ${serverConfig}"
            echo "Client config: ${clientConfig}"
            echo "WARP config:   ${serverWarpConfig}"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
