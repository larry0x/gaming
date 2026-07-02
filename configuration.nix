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
# 1. Install NixOS normally (minimal ISO, see image/). `nixos-generate-config`
#    produces /etc/nixos/hardware-configuration.nix (filesystems, microcode);
#    keep it.
# 2. Put this file at /etc/nixos/configuration.nix.
# 3. `nixos-rebuild switch`.
#
# TODO(larry): grep for "TODO" -- hostname, user password, GPU driver, WiFi,
# Bluetooth, and Tailscale are placeholders pending details.

{ lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix # generated during install; not hand-edited
  ];

  #### System ##################################################################

  time.timeZone = "UTC";

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
      "steam" # the Filesystem Hierarchy Standard (FHS) sandbox the client runs in (the `steam` command)
      "steam-unwrapped" # Valve's proprietary client itself, mounted inside the sandbox
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
    # Assumes UEFI. For legacy BIOS, use boot.loader.grub instead.
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };

    # Latest kernel for best support of recent GPUs and controllers.
    kernelPackages = pkgs.linuxPackages_latest;
  };

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
    # SSH public keys allowed to log in as this user. Managed declaratively:
    # written to /etc/ssh/authorized_keys.d/larry, not ~/.ssh/authorized_keys.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0WGLelGJfREUvxlyGW26jJvOte2sodtcYkXnhmo0RY openpgp:0xE1D94862"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPp84hGfIow1NeLZCJOo2voxJWyCgoJA9QA3cWufF7bA openpgp:0x0854DE69"
    ];
  };

  # To skip the password prompt entirely someday:
  # services.getty.autologinUser = "larry";
}
