{
  description = "vpntoggle - WireGuard profile toggle for OpenWrt (router scripts + .apk build)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # SDK build host tools (./build-apk.sh)
            docker # client only; the daemon must be enabled system-wide
            curl
            cacert
            gnutar
            zstd
            gzip
            xz
            coreutils
            findutils
            gnugrep
            gawk
            gnused
            gnumake
            git

            # router interaction (./router-audit.sh, ./migrate-to-apk.sh)
            openssh
            sshpass
          ];

          shellHook = ''
            echo "vpntoggle dev shell"
            echo
            echo "  ./build-apk.sh          build dist/*.apk with the OpenWrt SDK (Docker)"
            echo "  ./router-audit.sh       read-only audit of the router"
            echo "  ./migrate-to-apk.sh     migrate the router to the .apk packages"
            echo
            sock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
            if [ -z "''${DOCKER_HOST:-}" ] && [ -S "$sock" ]; then
              export DOCKER_HOST="unix://$sock"
            fi
            if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
              echo "docker: daemon reachable"
            else
              echo "docker: daemon NOT reachable."
              echo "  On NixOS import this flake's module: nixosModules.default"
              echo "  (it sets virtualisation.docker.rootless.enable = true;)"
            fi
          '';
        };
      });

      # NixOS module: system-side prerequisites for ./build-apk.sh.
      # Rootless Docker: the daemon runs as the user (no 'docker' group or
      # root needed), and setSocketVariable exports DOCKER_HOST for login
      # shells. build-apk.sh also auto-detects the rootless socket, so it
      # works even in shells that did not get that variable.
      nixosModules.default = { ... }: {
        virtualisation.docker.rootless = {
          enable = true;
          setSocketVariable = true;
        };
      };
      nixosModules.docker = self.nixosModules.default;

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
