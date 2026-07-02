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
  cp ci/hardware-configuration-stub.nix hardware-configuration.nix
  NIX_PATH=nixpkgs=channel:nixos-26.05 nix-instantiate '<nixpkgs/nixos>' -A system --arg configuration ./configuration.nix --argstr system x86_64-linux
  rm hardware-configuration.nix
