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
# TODO(larry): grep for "TODO" -- hostname and user password are placeholders
# pending details.

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

      # The NVIDIA driver's proprietary userspace (OpenGL/Vulkan libraries,
      # nvidia-smi, etc.).
      "nvidia-x11"
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

  hardware = {
    # Firmware blobs; GPUs, WiFi and Bluetooth chips all need these.
    enableRedistributableFirmware = true;

    # GPU: Gigabyte GeForce RTX 3080 Ti (GA102, Ampere generation). The
    # kernel driver is selected by services.xserver.videoDrivers below;
    # userspace graphics (Mesa, incl. 32-bit) is enabled by programs.steam.
    nvidia = {
      # Ampere and newer use NVIDIA's open kernel modules, recommended by
      # NVIDIA itself since driver 560. The userspace side (OpenGL/Vulkan
      # libraries, nvidia-smi) stays proprietary either way -- hence the
      # unfree exception in the System section.
      open = true;

      # Skip nvidia-settings, an X-based GUI tool (enabled by default),
      # useless on a box with no desktop.
      nvidiaSettings = false;
    };

    # Bluetooth, for the Xbox controller; the radio powers on at boot by
    # default (hardware.bluetooth.powerOnBoot). Pair from the TTY with
    # `bluetoothctl`.
    bluetooth.enable = true;

    # Driver for Xbox controllers over Bluetooth: correct button mappings,
    # rumble, battery reporting. Not part of the Linux kernel itself -- it is
    # a community-maintained module that NixOS builds separately against our
    # kernel. (Over USB, the kernel's own xpad driver already suffices.)
    xpadneo.enable = true;
  };

  # Despite the option's name, this loads the NVIDIA kernel driver for the
  # whole system, not just for X.
  services.xserver.videoDrivers = [ "nvidia" ];

  #### Networking ##############################################################

  networking = {
    hostName = "gaming"; # TODO

    # WiFi. iwd (iNet wireless daemon) is the minimalist supplicant; no
    # network manager needed. Connect once at the TTY:
    #
    # ```sh
    # iwctl station wlan0 connect <SSID>
    # ```
    #
    # and iwd saves the network to /var/lib/iwd, reconnecting automatically on
    # every boot after that.
    #
    # IP addressing, wired and wireless alike, is handled by dhcpcd, the NixOS default.
    wireless.iwd.enable = true;

    # The NixOS firewall is enabled by default: everything inbound is dropped
    # unless a port is opened here or by a module. The single exception: SSH,
    # reachable only from within the tailnet.
    firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 ];
  };

  # Remote administration from another machine, so this box never needs more
  # than a TTY. Enabling brings the sshd binary and its systemd unit; nothing
  # to add to systemPackages.
  services.openssh = {
    enable = true;

    # Enabling sshd normally also punches a hole in the firewall -- port 22
    # open on ALL interfaces (this option defaults to true). Opt out of that,
    # leaving the tailscale0 rule under networking.firewall above as the only
    # way in.
    openFirewall = false;

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

  # Mesh VPN; SSH is only reachable through it. Enabling this installs and
  # starts the daemon (tailscaled) in a logged-out state -- joining a tailnet
  # is a one-time imperative step, never part of nixos-rebuild. After first
  # boot:
  #
  # ```sh
  # sudo tailscale up
  # ```
  #
  # then open the login URL it prints in a browser on another device (e.g.
  # the Mac) and complete the sign-in there. Any identity provider works,
  # including Sign in with Apple -- this machine never sees the credentials,
  # it only receives the resulting authorization.
  #
  # The node state lives in /var/lib/tailscale, surviving reboots and
  # rebuilds.
  services.tailscale.enable = true;

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
