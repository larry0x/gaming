# Minimalist NixOS gaming machine.
#
# Design:
#
# - No desktop environment, no display manager, not even an X server. NixOS
#   boots to a plain TTY (getty) by default, so there is nothing to disable.
# - Steam cannot draw on a bare TTY -- it needs *a* display server. The
#   lightest one that works is gamescope, Valve's micro-compositor (the same
#   thing SteamOS runs), which drives the GPU directly via DRM/KMS.
# - Flow: boot -> log in on the TTY -> run `steam-gamescope` -> Steam Big
#   Picture. Quitting Steam drops you back to the TTY.
#
# Install workflow:
#
# 1. Install NixOS normally (minimal ISO). `nixos-generate-config` produces
#    /etc/nixos/hardware-configuration.nix (filesystems, microcode); keep it.
# 2. Put this file at /etc/nixos/configuration.nix.
# 3. `nixos-rebuild switch`.
#
# TODO(larry): grep for "TODO" -- hostname, timezone, user, GPU driver, WiFi,
# and Bluetooth are placeholders pending hardware details.

{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix # generated during install; not hand-edited
  ];

  #### Boot ####################################################################

  # Assumes UEFI. For legacy BIOS, use boot.loader.grub instead.
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  # Latest kernel for best support of recent GPUs and controllers.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  #### Hardware ################################################################

  # Firmware blobs; GPUs, WiFi and Bluetooth chips all need these.
  hardware.enableRedistributableFirmware = true;

  # Userspace graphics (Mesa) incl. 32-bit, which the Steam client and many
  # games require. programs.steam.enable would set these anyway; kept explicit.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # GPU driver -- TODO: fill in once the card is known.
  #
  # AMD: nothing needed beyond Mesa above (kernel amdgpu driver is built in).
  #   hardware.amdgpu.initrd.enable = true; # optional: KMS in initrd
  #
  # NVIDIA (proprietary; despite the option name this is not X-specific):
  #   services.xserver.videoDrivers = [ "nvidia" ];
  #   hardware.nvidia.modesetting.enable = true; # required for gamescope
  #   hardware.nvidia.open = true;               # Turing (RTX 20xx) or newer

  # Bluetooth (controllers) -- TODO once hardware is known:
  # hardware.bluetooth.enable = true;
  # hardware.bluetooth.powerOnBoot = true;
  # hardware.xpadneo.enable = true; # better driver for Xbox controllers over BT

  #### Networking ##############################################################

  networking.hostName = "gaming"; # TODO

  # Wired ethernet with DHCP works out of the box; nothing to configure.
  # WiFi -- TODO: iwd is the minimalist choice, configured interactively
  # with `iwctl`:
  # networking.wireless.iwd.enable = true;

  # Steam networking extras, if ever wanted:
  # programs.steam.remotePlay.openFirewall = true;
  # programs.steam.localNetworkGameTransfers.openFirewall = true;

  #### Audio ###################################################################

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true; # most games speak the PulseAudio protocol
  };
  security.rtkit.enable = true; # lets PipeWire acquire realtime scheduling

  #### Steam + gamescope #######################################################

  programs.steam = {
    # Also pulls in Proton and controller udev rules. Enable Proton for all
    # titles in Steam: Settings > Compatibility, after first login.
    enable = true;

    # Provides the `steam-gamescope` command: gamescope running directly on
    # DRM/KMS with Steam Big Picture inside it.
    gamescopeSession = {
      enable = true;
      # Extra gamescope flags -- TODO: tune once the display is known, e.g.:
      # args = [ "-W" "3840" "-H" "2160" "-r" "120" "--adaptive-sync" "--hdr-enabled" ];
    };

    # Community Proton build; runs some games upstream Proton chokes on:
    # extraCompatPackages = [ pkgs.proton-ge-bin ];
  };

  programs.gamescope = {
    enable = true;
    # Realtime priority for the compositor thread; smooths out frame times.
    # Enable once the basic setup is confirmed working -- if steam-gamescope
    # ever fails to start, this is the first thing to turn back off.
    # capSysNice = true;
  };

  # CPU governor / niceness tweaks while a game is running:
  # programs.gamemode.enable = true;

  #### Users ###################################################################

  users.users.larry = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # sudo
    # TTY login password. CHANGE THIS after first boot with `passwd`, or
    # replace with hashedPassword (generate one via `mkpasswd -m sha-512`).
    initialPassword = "changeme";
  };

  # To skip the password prompt entirely someday:
  # services.getty.autologinUser = "larry";

  #### System ##################################################################

  # time.timeZone = "..."; # TODO

  # Handy when the box misbehaves; delete if you want it truly bare.
  environment.systemPackages = with pkgs; [ vim git ];

  # Remote administration from another machine, so this box never needs more
  # than a TTY. Uncomment if wanted:
  # services.openssh.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Steam is unfree; this keeps the exception narrowly scoped instead of a
  # blanket allowUnfree. Extend the list if the GPU turns out to be NVIDIA
  # ("nvidia-x11", "nvidia-settings").
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "steam"
      "steam-unwrapped"
      "steam-original"
      "steam-run"
    ];

  # The NixOS release this machine was FIRST installed with. Set it once at
  # install time and never change it, even when upgrading later.
  system.stateVersion = "25.11"; # TODO: match your install media
}
