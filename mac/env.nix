# My macOS development environment: a single buildEnv holding every
# development tool, installed into the user profile via `nix profile add` so
# that everything is available in every shell.

{ pkgs, fenixPkgs }:
let
  # The stable toolchain, pinned by flake.lock. There is deliberately no
  # nightly anything here — my projects format with stable rustfmt.
  rustToolchain = fenixPkgs.stable.withComponents [
    "cargo"
    "clippy"
    "rust-src"
    "rustc"
    "rustfmt"
  ];

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

      # Integrity hash of the source tarball; the fetch fails if crates.io
      # ever serves different bytes for this name and version.
      hash = "sha256-F6ozNlN8umagAWr+xeA61uf+QOae/y6VnyzWKDsFIhk=";
    };

    # Same, for the vendored dependency tree (everything in the crate's
    # Cargo.lock), which is fetched in a separate step so the build itself
    # can run offline.
    cargoHash = "sha256-LUHVGEvE22ITlmpuI+8qGBPTa7q8YssiLSfQnvGM4hw=";

    # Skip the crate's own test suite; the released binary is all we need.
    doCheck = false;
  };
in
pkgs.buildEnv {
  name = "dev";
  paths = [
    # Rust
    rustToolchain
    pkgs.rust-analyzer
    pkgs.cargo-machete

    # mdBook
    pkgs.mdbook
    pkgs.mdbook-mermaid
    mdbook-katex

    # Just
    pkgs.just
    pkgs.just-lsp

    # TOML
    pkgs.taplo

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

    # Secrets / YubiKey. gpg-agent doubles as the SSH agent, with the private
    # keys living on the YubiKey; pinentry-mac provides the GUI PIN prompt
    # (its path is wired into ~/.gnupg/gpg-agent.conf, and git's gpg.program
    # points at the gpg here).
    pkgs.gnupg
    pkgs.pinentry_mac
    pkgs.sops
    pkgs.age
    pkgs.age-plugin-yubikey
    pkgs.yubikey-manager

    # CLI utilities
    pkgs.bat
    pkgs.direnv
    pkgs.dust
    pkgs.eza
    pkgs.fastfetch
    pkgs.gh
    pkgs.gitleaks
    pkgs.jq
    pkgs.ripgrep
    pkgs.starship
    pkgs.tokei

    # Nix tooling. nixos-rebuild-ng deploys the PC's NixOS from this Mac over
    # SSH (`just pc-deploy`): evaluation happens locally (it is pure and
    # platform-independent), the build and activation on the PC. Despite the
    # -ng attribute name, the binary it installs is plain `nixos-rebuild`.
    pkgs.nixd
    pkgs.nixfmt
    pkgs.statix
    pkgs.deadnix
    pkgs.nixos-rebuild-ng
  ];
}
