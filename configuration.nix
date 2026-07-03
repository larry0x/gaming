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
# 1. Install NixOS normally (minimal ISO, see image/).
# 2. Clone this repo onto the machine. Overwrite the placeholder
#    hardware-configuration.nix with the machine's real one, generated during
#    install, and commit it:
#    `nixos-generate-config --show-hardware-config > hardware-configuration.nix`
# 3. `sudo nixos-rebuild switch --flake .#gaming`. (Once the hostname is set,
#    plain `--flake .` also works: it selects the config whose name matches
#    the hostname.)
#
# TODO(larry): grep for "TODO" -- hostname, user password, GPU driver, WiFi,
# Bluetooth, and Tailscale are placeholders pending details.

{ lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix # placeholder until install day; see workflow above
  ];

  #### System ##################################################################

  time.timeZone = "UTC";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Makes these packages' commands available in every user's shell.
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  # Remote administration from another machine, so this box never needs more
  # than a TTY. This one option brings the sshd binary, its systemd unit, and
  # a firewall exception for port 22; nothing to add to systemPackages. (The
  # port-22 exception currently applies on all interfaces -- to be restricted
  # to the tailnet; see the Tailscale TODO under Networking.)
  services.openssh = {
    enable = true;
    settings = {
      # Key-only login; the keys live in users.users.larry below.
      PasswordAuthentication = false;

      # "Keyboard-interactive" is a challenge-response scheme where the server
      # drives arbitrary prompts -- in practice, PAM conversations such as
      # passwords or OTP codes. It is a second password-style path into the
      # box, so key-only login means closing it as well.
      KbdInteractiveAuthentication = false;
    };
  };

  # "Unfree" is nixpkgs jargon for a package whose license is not a free/open
  # source one. Nixpkgs refuses to install unfree packages unless opted in.
  # This predicate scopes whether a package is to be opted in.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      # The Filesystem Hierarchy Standard (FHS) sandbox the client runs in
      # (the `steam` command).
      "steam"

      # Valve's proprietary client itself, mounted inside the sandbox.
      "steam-unwrapped"
    ];

  # The NixOS release this machine was FIRST installed with; *not* "the version
  # currently running".
  # It tells stateful components which era of on-disk formats and defaults their
  # data was created with.
  # Set once at install time and never changed afterwards, even when upgrading
  # the system later.
  system.stateVersion = "26.05";

  #### Boot ####################################################################

  boot = {
    loader = {
      systemd-boot = {
        # Replaces GRUB, the default, as the more minimalist choice: a plain
        # UEFI boot menu -- no drivers, no scripting -- that also needs fewer
        # options to set. (Assumes UEFI; on legacy BIOS, GRUB is the only
        # choice.)
        enable = true;

        # Only keep boot menu entries for the 10 newest generations.
        # A "generation" is a complete bootable snapshot of the entire OS,
        # created per nixos-rebuild. Each entry copies its kernel + initrd onto
        # the EFI System Partition, a small FAT filesystem that fills up --
        # failing future rebuilds -- if entries accumulate unbounded. Older
        # generations still exist in /nix/store until garbage-collected; they
        # only lose their menu entry.
        configurationLimit = 10;
      };

      # Let the bootloader installer write EFI variables in the firmware's
      # NVRAM (what `efibootmgr` does on other distros), registering
      # systemd-boot in the firmware's boot order. Without this, the loader is
      # only placed at the ESP's fallback path and firmware settings are left
      # untouched.
      efi.canTouchEfiVariables = true;
    };

    # The default is pkgs.linuxPackages, the release's LTS kernel (6.18.x on
    # 26.05); _latest is mainline (7.1.x), preferred because support for new
    # GPUs, controllers, and HDR lands there first -- exactly what a gaming
    # box wants.
    # Not a reproducibility hole: "latest" resolves inside the nixpkgs revision
    # pinned by flake.lock, so rebuilds always yield the same kernel. It only
    # changes which version a future `nix flake update` may jump to.
    kernelPackages = pkgs.linuxPackages_latest;
  };

  #### Hardware ################################################################

  # Firmware blobs; GPUs, WiFi and Bluetooth chips all need these.
  hardware.enableRedistributableFirmware = true;

  # Userspace graphics (Mesa, incl. 32-bit) is enabled by programs.steam.

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

  # The NixOS firewall is enabled by default: everything inbound is dropped
  # unless a port is opened here or by a module (as services.openssh does).
  #
  # TODO: Tailscale, then restrict SSH to the tailnet. The plan:
  #   services.tailscale.enable = true;
  #   services.openssh.openFirewall = false; # stop opening port 22 globally...
  #   networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 ]; # ...allow it from the tailnet only

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

  # gamescope itself is enabled by gamescopeSession above. If frame times need
  # smoothing, grant the compositor realtime priority -- but should
  # steam-gamescope ever fail to start, turn this back off first:
  # programs.gamescope.capSysNice = true;

  # CPU governor / niceness tweaks while a game is running:
  # programs.gamemode.enable = true;

  #### Users ###################################################################

  users.users.larry = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # sudo

    # TTY login password. CHANGE THIS after first boot with `passwd`, or
    # replace with hashedPassword (generate one via `mkpasswd -m sha-512`).
    initialPassword = "changeme";

    # SSH public keys allowed to log in as this user. Managed declaratively:
    # written to /etc/ssh/authorized_keys.d/larry, not ~/.ssh/authorized_keys.
    openssh.authorizedKeys.keys = [
      # larry_yubikey_082.pub
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0WGLelGJfREUvxlyGW26jJvOte2sodtcYkXnhmo0RY openpgp:0xE1D94862"

      # larry_yubikey_093.pub
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPp84hGfIow1NeLZCJOo2voxJWyCgoJA9QA3cWufF7bA openpgp:0x0854DE69"
    ];
  };

  # To skip the password prompt entirely someday:
  # services.getty.autologinUser = "larry";
}
