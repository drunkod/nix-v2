{
  description = "A V2Ray server and client flake with optional WARP egress";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # Or a specific release
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Corrected package name: v2ray instead of v2fly-core
        v2rayPackage = pkgs.v2ray;

        # Path to config files within the flake
        serverConfig = ./v2ray-server-config.json;
        clientConfig = ./v2ray-client-config.json;
        serverWarpConfig = ./v2ray-server-config-warp.json;

      in
      {
        packages = {
          v2ray-server = pkgs.writeShellScriptBin "run-v2ray-server" ''
            #!${pkgs.stdenv.shell}
            echo "Starting V2Ray server with config: ${serverConfig}"
            echo "Make sure port 8080 is open and client config points to this machine."
            ${v2rayPackage}/bin/v2ray run -config ${serverConfig}
          '';

          v2ray-client = pkgs.writeShellScriptBin "run-v2ray-client" ''
            #!${pkgs.stdenv.shell}
            echo "Starting V2Ray client with config: ${clientConfig}"
            echo "Ensure you have edited ${clientConfig} with the correct server address."
            echo "SOCKS5 proxy will be available on 127.0.0.1:10808"
            ${v2rayPackage}/bin/v2ray run -config ${clientConfig}
          '';

          # You can also just expose the core v2ray package
          v2ray = v2rayPackage;

          # WARP setup: register account and generate wireproxy config
          warp-setup = pkgs.writeShellScriptBin "warp-setup" ''
            #!${pkgs.stdenv.shell}
            set -euo pipefail

            mkdir -p warp
            cd warp

            if [ ! -f wgcf-account.toml ]; then
              echo "Registering WARP account..."
              ${pkgs.wgcf}/bin/wgcf register --accept-tos
            else
              echo "WARP account already exists, skipping registration."
            fi

            if [ ! -f wgcf-profile.conf ]; then
              echo "Generating WireGuard profile..."
              ${pkgs.wgcf}/bin/wgcf generate
            else
              echo "WireGuard profile already exists, skipping generation."
            fi

            echo "Creating wireproxy.conf..."
            cp wgcf-profile.conf wireproxy.conf
            # Append Socks5 section if not already present
            if ! grep -q '^\[Socks5\]' wireproxy.conf; then
              printf '\n[Socks5]\nBindAddress = 127.0.0.1:40000\n' >> wireproxy.conf
            fi

            echo "Done. Files in warp/:"
            ls -la
            echo ""
            echo "Next: run 'nix run .#warp-proxy' then 'nix run .#server-warp'"
          '';

          # wireproxy: SOCKS5 proxy over WARP
          warp-proxy = pkgs.writeShellScriptBin "warp-proxy" ''
            #!${pkgs.stdenv.shell}
            set -euo pipefail

            if [ ! -f /root/work/nix-v2/warp/wireproxy.conf ]; then
              echo "Error: /root/work/nix-v2/warp/wireproxy.conf not found. Run 'nix run .#warp-setup' first."
              exit 1
            fi

            echo "Starting wireproxy (SOCKS5 on 127.0.0.1:40000)..."
            exec ${pkgs.wireproxy}/bin/wireproxy -c /root/work/nix-v2/warp/wireproxy.conf
          '';

          # V2Ray server with WARP egress (requires running warp-proxy)
          v2ray-server-warp = pkgs.writeShellScriptBin "run-v2ray-server-warp" ''
            #!${pkgs.stdenv.shell}
            echo "Starting V2Ray server with WARP egress config: ${serverWarpConfig}"
            echo "Ensure wireproxy is running (nix run .#warp-proxy)"
            exec ${v2rayPackage}/bin/v2ray run -config ${serverWarpConfig}
          '';

          # All-in-one: wireproxy + V2Ray in a single process
          v2ray-server-warp-all = pkgs.writeShellScriptBin "run-v2ray-server-warp-all" ''
            #!${pkgs.stdenv.shell}
            set -euo pipefail

            if [ ! -f /root/work/nix-v2/warp/wireproxy.conf ]; then
              echo "Error: /root/work/nix-v2/warp/wireproxy.conf not found. Run 'nix run .#warp-setup' first."
              exit 1
            fi

            cleanup() {
              echo "Shutting down..."
              kill "$WIREPROXY_PID" 2>/dev/null || true
              wait "$WIREPROXY_PID" 2>/dev/null || true
              echo "Done."
            }
            trap cleanup EXIT INT TERM

            echo "Starting wireproxy (SOCKS5 on 127.0.0.1:40000)..."
            ${pkgs.wireproxy}/bin/wireproxy -c /root/work/nix-v2/warp/wireproxy.conf &
            WIREPROXY_PID=$!

            echo "Waiting 2 seconds for wireproxy to start..."
            sleep 2

            echo "Starting V2Ray server with WARP egress..."
            ${v2rayPackage}/bin/v2ray run -config ${serverWarpConfig}
          '';
        };

        apps = {
          server = {
            type = "app";
            program = "${self.packages.${system}.v2ray-server}/bin/run-v2ray-server";
          };
          client = {
            type = "app";
            program = "${self.packages.${system}.v2ray-client}/bin/run-v2ray-client";
          };
          warp-setup = {
            type = "app";
            program = "${self.packages.${system}.warp-setup}/bin/warp-setup";
          };
          warp-proxy = {
            type = "app";
            program = "${self.packages.${system}.warp-proxy}/bin/warp-proxy";
          };
          server-warp = {
            type = "app";
            program = "${self.packages.${system}.v2ray-server-warp}/bin/run-v2ray-server-warp";
          };
          server-warp-all = {
            type = "app";
            program = "${self.packages.${system}.v2ray-server-warp-all}/bin/run-v2ray-server-warp-all";
          };
        };

        defaultApp = self.apps.${system}.server;

        devShells.default = pkgs.mkShell {
          name = "v2ray-dev-shell";
          buildInputs = [
            v2rayPackage
            pkgs.curl # For testing
            pkgs.wgcf
            pkgs.wireproxy
          ];
          shellHook = ''
            echo "V2Ray dev shell. 'v2ray', 'wgcf', 'wireproxy' commands are available."
            echo "Server config: ${serverConfig}"
            echo "Client config: ${clientConfig} (edit if needed)"
            echo "WARP config:   ${serverWarpConfig}"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
