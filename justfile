# List available recipes
default:
  @just --list

# Format all Nix files in place
fmt:
  nixfmt $(git ls-files '*.nix')

# Run the linters
lint:
  statix check .
  deadnix --fail .

# Type-check by evaluating the full NixOS system
test:
  nix eval .#nixosConfigurations.gaming.config.system.build.toplevel.drvPath

# Install NixOS for the first time
install:
  sudo nixos-generate-config --root /mnt --show-hardware-config > pc/hardware-configuration.nix
  sudo nixos-install --flake .#gaming --no-root-passwd

# Rebuild NixOS
rebuild:
  sudo nixos-rebuild switch --flake .#gaming
