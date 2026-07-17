{
  description = "Minimalist NixOS gaming machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { nixpkgs, ... }:
    {
      nixosConfigurations.gaming = nixpkgs.lib.nixosSystem {
        modules = [ ./pc/configuration.nix ];
      };
    };
}
