{
  description = "Nix setup for my working and gaming computers";

  inputs = {
    # The rolling branch, so packages stay current instead of feature-freezing
    # for six months at a time as the stable branches do. Despite the name, it
    # only advances after Hydra CI passes — a CI-gated rolling release, not
    # untested software.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Rust toolchain for the mac environment, repackaging the official
    # rust-lang binary releases under Nix pins.
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, fenix, ... }:
    {
      nixosConfigurations.gaming = nixpkgs.lib.nixosSystem {
        modules = [ ./pc/configuration.nix ];
      };

      packages.aarch64-darwin.default = import ./mac/env.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        fenixPkgs = fenix.packages.aarch64-darwin;
      };
    };
}
