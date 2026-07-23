# List available recipes
default:
  @just --list

# -------------------------------- Development ---------------------------------

# Format all Nix files in place
fmt:
  nixfmt $(git ls-files '*.nix')

# Run the linters
lint:
  statix check .
  deadnix --fail .

# Type-check by evaluating the full NixOS system and the mac environment
test:
  nix eval .#nixosConfigurations.gaming.config.system.build.toplevel.drvPath
  nix eval .#packages.aarch64-darwin.default.drvPath

# Update all flake inputs
update:
  nix flake update

# ------------------------------------- PC -------------------------------------

# Install NixOS for the first time
pc-install:
  sudo nixos-generate-config --root /mnt --show-hardware-config > pc/hardware-configuration.nix
  sudo nixos-install --flake .#gaming --no-root-passwd

# Rebuild NixOS (run on the PC itself)
pc-rebuild:
  sudo nixos-rebuild switch --flake .#gaming

# Deploy NixOS to the PC from this Mac: evaluate here, build + activate there over SSH
pc-deploy:
  nixos-rebuild switch --flake .#gaming --target-host gaming --build-host gaming --elevate sudo --ask-elevate-password

# ------------------------------------ Mac -------------------------------------

# Install the mac dev environment into the user profile (first time only)
mac-add:
  nix profile add .

# Rebuild the mac dev environment after changing it
mac-upgrade:
  nix profile upgrade --all
