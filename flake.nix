{
  description = "A V2Ray server flake with custom, updatable geo data";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # --- Определения для Geo-данных (остаются без изменений) ---
        # Скрипт будет обновлять значения sha256 здесь.
        customGeosite = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/geosite.dat";
          sha256 = "0na8k48f4vj0w2m99bs09d7q59c8j18n6qf6vj710z9r75x58i66"; # GEOSITE_HASH
        };

        customGeoip = pkgs.fetchurl {
          url = "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat";
          sha256 = "19q4h2c2b3d1r4549i62y7l996j2l99m5180k3w2w891m6i3l559"; # GEOIP_HASH
        };

        v2rayAssets = pkgs.runCommand "v2ray-assets" { } ''
          mkdir -p $out
          ln -s ${customGeosite} $out/geosite.dat
          ln -s ${customGeoip} $out/geoip.dat
        '';

      in
      {
        packages = {
          v2ray-server = pkgs.writeShellScriptBin "run-v2ray-server" ''
            #!${pkgs.stdenv.shell}
            export V2RAY_LOCATION_ASSET=${v2rayAssets}
            echo "Starting V2Ray server with custom assets from: ''${V2RAY_LOCATION_ASSET}"
            ${pkgs.v2ray}/bin/v2ray run -config ${./v2ray-server-config.json}
          '';

          # --- ИЗМЕНЕНИЕ ЗДЕСЬ ---
          # Упаковываем внешний скрипт вместо встраивания его в flake.nix
          update-dat-files = pkgs.writeShellApplication {
            name = "update-dat-files";

            # Указываем программы, которые нужны нашему скрипту для работы.
            # Nix добавит их в PATH внутри окружения скрипта.
            runtimeInputs = with pkgs; [
              curl
              coreutils # для sha256sum
              gnused    # для sed -i
              nix-prefetch-scripts # для nix-prefetch-url
            ];

            # Читаем текст скрипта из файла.
            text = builtins.readFile ./update-data.sh;
          };

          v2ray-client = pkgs.writeShellScriptBin "run-v2ray-client" ''
            #!${pkgs.stdenv.shell}
            ${pkgs.v2ray}/bin/v2ray run -config ${./v2ray-client-config.json}
          '';

          v2ray = pkgs.v2ray;
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
          # Приложение теперь указывает на наш новый пакет
          update-data = {
            type = "app";
            program = "${self.packages.${system}.update-dat-files}/bin/update-dat-files";
          };
        };

        defaultApp = self.apps.${system}.server;

        devShells.default = pkgs.mkShell {
          name = "v2ray-dev-shell";
          packages = [
            pkgs.v2ray
            pkgs.curl
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    );
}