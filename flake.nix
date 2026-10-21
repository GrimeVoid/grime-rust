{
  description = "Grime - Modular single-binary workspace and task orchestration system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f (import nixpkgs { inherit system; }));

      # Функция создания пакета Grime
      makeGrimePackage = pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "grime";
          version = "1.1.0";

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs = [ ];

          # Прогон тестов при сборке
          doCheck = false; # Можно включить true при необходимости

          meta = with pkgs.lib; {
            description = "Grime modular single-binary workspace & execution orchestrator";
            homepage = "https://github.com/GrimeVoid/grime-rust";
            license = licenses.mit;
            maintainers = [ ];
            mainProgram = "grime";
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        # Стандартный бинарник Nix (с nix-версией glibc)
        default = makeGrimePackage pkgs;

        # Полностью автономный статический бинарник (musl libc),
        # гарантированно запускающийся на ЛЮБЫХ Linux-дистрибутивах без glibc конфликтов.
        static = makeGrimePackage pkgs.pkgsStatic;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "grime-dev-shell";

          nativeBuildInputs = with pkgs; [
            cargo
            rustc
            rust-analyzer
            clippy
            rustfmt
            pkg-config
            gcc
          ];

          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
        };
      });
    };
}
