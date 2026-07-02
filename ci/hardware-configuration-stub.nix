# Stand-in for the machine-generated /etc/nixos/hardware-configuration.nix, so
# that the NixOS eval check can run away from the box (in CI, or locally).
# Never deploy this file: the machine has its own, real, generated one.

{ lib, ... }:

{
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
