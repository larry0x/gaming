# My macOS development environment: a single buildEnv holding every
# development tool, installed into the user profile via `nix profile add` so
# that everything is available in every shell.

{ pkgs, fenixPkgs }:
let
  # ----------------------------------- Rust -----------------------------------

  # The stable toolchain, pinned by flake.lock. There is deliberately no
  # nightly anything here — my projects format with stable rustfmt.
  rustToolchain = fenixPkgs.stable.withComponents [
    "cargo"
    "clippy"
    "rust-src"
    "rustc"
    "rustfmt"
  ];

  # ----------------------------------- Docs -----------------------------------

  # mdbook and mdbook-mermaid come stock from nixpkgs. mdbook-katex must be
  # built from source, because nixpkgs ships a stale version that predates
  # mdbook 0.5.
  #
  # Nix builds honor each preprocessor crate's shipped Cargo.lock (unlike a
  # bare `cargo install`, which re-resolves dependencies at install time), so
  # the mdbook libraries they link are often slightly older than the mdbook
  # binary calling them. Each such preprocessor then prints a one-line "built
  # against version X" warning per mdbook run. This is cosmetic: KaTeX math
  # and mermaid diagrams render fine regardless.
  mdbook-katex = pkgs.rustPlatform.buildRustPackage rec {
    pname = "mdbook-katex";
    version = "0.10.0-alpha";

    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-F6ozNlN8umagAWr+xeA61uf+QOae/y6VnyzWKDsFIhk=";
    };

    cargoHash = "sha256-LUHVGEvE22ITlmpuI+8qGBPTa7q8YssiLSfQnvGM4hw=";
    doCheck = false;
  };
in
pkgs.buildEnv {
  name = "dev";
  paths = [
    # Rust
    rustToolchain
    pkgs.rust-analyzer
    pkgs.just
    pkgs.taplo
    pkgs.cargo-machete
    pkgs.cargo-flamegraph

    # Docs
    pkgs.mdbook
    pkgs.mdbook-mermaid
    mdbook-katex

    # JavaScript / TypeScript
    pkgs.nodejs_24
    pkgs.pnpm
    pkgs.typescript
    pkgs.typescript-language-server

    # Python
    pkgs.python314
    pkgs.uv

    # Containers (daemon = colima; no Docker Desktop, no OrbStack)
    pkgs.colima
    pkgs.docker-client
    pkgs.docker-compose
    pkgs.docker-buildx

    # Secrets / YubiKey
    pkgs.sops
    pkgs.age
    pkgs.age-plugin-yubikey
    pkgs.yubikey-manager

    # CLI utilities. coreutils is the GNU one, unprefixed — it deliberately
    # shadows the stock BSD tools (ls, date, stat, …).
    pkgs.coreutils
    pkgs.bat
    pkgs.eza
    pkgs.starship
    pkgs.fastfetch
    pkgs.direnv
    pkgs.gh
    pkgs.jq
    pkgs.yq-go
    pkgs.ripgrep
    pkgs.wget
    pkgs.tokei
    pkgs.websocat
    pkgs.gitleaks
    pkgs.zizmor
    pkgs.wabt

    # Nix tooling
    pkgs.nixd
    pkgs.nixfmt
    pkgs.statix
    pkgs.deadnix
  ];
}
