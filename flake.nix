{
  description = "A V2Ray server and client flake for simple testing";

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
        };

        defaultApp = self.apps.${system}.server;

        devShells.default = pkgs.mkShell {
          name = "v2ray-dev-shell";
          buildInputs = [
            v2rayPackage
            pkgs.curl # For testing
          ];
          shellHook = ''
            echo "V2Ray dev shell. 'v2ray' command is available."
            echo "Server config: ${serverConfig}"
            echo "Client config: ${clientConfig} (edit if needed)"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
