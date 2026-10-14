{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
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
}
