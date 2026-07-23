# Minimalist NixOS gaming machine.
#
# Design:
#
# - No desktop environment, no display manager, not even an X server. NixOS
#   boots to a plain TTY (getty) by default, so there is nothing to disable.
# - Steam cannot draw on a bare TTY -- it needs *a* display server. The
#   lightest one that works is gamescope, Valve's micro-compositor (the same
#   thing SteamOS runs), which drives the GPU directly via DRM/KMS.
# - Flow: boot -> getty auto-logs larry in on tty1 -> the login shell launches
#   `steam-gamescope` -> Steam Big Picture, with no input anywhere. Quitting
#   Steam ("Switch to Desktop" in Big Picture) drops to a logged-in shell on
#   tty1; logging out of it (Ctrl-D) brings Big Picture back.
#
# Install workflow:
#
# 1. Install NixOS normally (minimal ISO, see image/).
# 2. Clone this repo onto the machine. Overwrite hardware-configuration.nix
#    with the machine's real one, generated during install, and commit it:
#    `nixos-generate-config --show-hardware-config > hardware-configuration.nix`
# 3. `sudo nixos-rebuild switch --flake .#gaming`. (Once the hostname is set,
#    plain `--flake .` also works: it selects the config whose name matches
#    the hostname.)

{ lib, pkgs, ... }:

{
  imports = [
    # The machine's real, generated hardware-configuration.nix. To refresh it
    # after a hardware change, run on the box:
    # `sudo nixos-generate-config --show-hardware-config`; then, to satisfy
    # our tooling: `just fmt`, and drop the unused `pkgs` argument the
    # generator emits (deadnix).
    ./hardware-configuration.nix
  ];

  #### System ##################################################################

  time.timeZone = "UTC";

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Garbage collection: nothing sweeps /nix/store by default, and on this box
    # every generation pins a kernel, the NVIDIA driver, and Steam's closure --
    # gigabytes per rebuild, accumulating unbounded. This timer runs
    # `nix-collect-garbage --delete-older-than 30d` weekly: generations older
    # than 30 days lose their profile entry, then store paths no longer
    # reachable from any remaining generation (or other GC root) are deleted.
    # The current generation is never deleted.
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # Makes these packages' commands available in every user's shell.
  environment.systemPackages = with pkgs; [
    fastfetch
    git
    just
    mangohud
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

  #### Users ###################################################################

  # Besides the accounts declared here, NixOS creates a few dozen system
  # accounts for daemons (sshd, rtkit, nixbld1..32 for sandboxed Nix builds,
  # ...), all with logins disabled.

  # Lock root: "!" is the shadow-file convention for "no password matches".
  # Root would be created locked anyway when no password is specified; this
  # makes the invariant explicit -- and enforced even if users.mutableUsers
  # is ever set to false. Root work happens via `sudo -i`. At install time,
  # pass `--no-root-passwd` to nixos-install so it does not prompt to set a
  # root password imperatively (which would override this until re-locked).
  users.users.root.hashedPassword = "!";

  users.users.larry = {
    # A "normal" user is a human login account: a home directory under /home,
    # a uid from 1000 up, membership of the "users" group, a login shell. The
    # abnormal kind (isSystemUser) is those daemon accounts: system-range
    # uid, no home, nologin shell. Exactly one of the two must be true.
    isNormalUser = true;

    extraGroups = [ "wheel" ]; # sudo

    # Meant to live only until the first boot: change it right away with
    # `passwd`. The change sticks -- users.mutableUsers defaults to true,
    # making passwords machine state like the WiFi and Tailscale credentials.
    # Auto-login (see the last section) means no console prompt ever asks for
    # this password; its remaining job is gating sudo. A plaintext "123" here
    # is acceptable because SSH password login is disabled: no remote path
    # accepts any password.
    initialPassword = "123";

    # SSH public keys allowed to log in as this user. Managed declaratively:
    # written to /etc/ssh/authorized_keys.d/larry, not ~/.ssh/authorized_keys.
    openssh.authorizedKeys.keys = [
      # larry_yubikey_082.pub
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF0WGLelGJfREUvxlyGW26jJvOte2sodtcYkXnhmo0RY openpgp:0xE1D94862"

      # larry_yubikey_093.pub
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPp84hGfIow1NeLZCJOo2voxJWyCgoJA9QA3cWufF7bA openpgp:0x0854DE69"
    ];
  };

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
        # generations still exist in /nix/store until garbage-collected (the
        # nix.gc timer in the System section); they only lose their menu entry.
        configurationLimit = 10;
      };

      # Let the bootloader installer write EFI variables in the firmware's
      # NVRAM (what `efibootmgr` does on other distros), registering
      # systemd-boot in the firmware's boot order. Without this, the loader is
      # only placed at the ESP's fallback path and firmware settings are left
      # untouched.
      efi.canTouchEfiVariables = true;
    };

    # The board's Bluetooth radio is unused: both peripherals (keyboard,
    # controller) connect via their 2.4G USB dongles instead, after Bluetooth
    # proved incompatible with suspend -- a BLE keyboard advertises whenever
    # it is powered but unconnected (on power-on, and after the disconnect
    # that suspending itself performs), and the kernel counts any
    # advertisement from a bonded HID device as a wake request, so the box
    # woke right back up whenever the keyboard was on. Keep btusb from
    # binding the radio at all; without it, bluetoothd (dropped from the
    # config along with the xpadneo driver) would have nothing to drive
    # anyway.
    blacklistedKernelModules = [ "btusb" ];
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

      # Preserve video memory across suspend: the nvidia-suspend/nvidia-resume
      # systemd services save in-use VRAM to /tmp (on disk here) before S3 and
      # restore it after. Without this the GPU comes back with VRAM empty --
      # gamescope's buffers are gone, its page-flip never completes ("Flip
      # event timeout" from nvidia-drm), and the screen stays dead even though
      # the system resumed fine underneath (SSH still works). Costs a few
      # seconds per suspend/resume for the VRAM round-trip.
      powerManagement.enable = true;
    };

  };

  # Despite the option's name, this loads the NVIDIA kernel driver for the
  # whole system, not just for X.
  services.xserver.videoDrivers = [ "nvidia" ];

  # Wake-from-suspend by the keyboard's 2.4G USB dongle. The kernel enables
  # USB remote wakeup by default for keyboard-class HID interfaces -- which
  # is why the dongle itself needs no rule here, and why the controller's
  # dongle (a vendor-class gamepad) cannot wake the box -- but the keypress
  # signal only reaches the platform if every hop above the dongle is armed
  # too, and those default to off: the root hub, and the xHCI PCI function
  # whose PME raises the ACPI wake event. Both belong to the chipset xHCI at
  # 0000:02:00.0. The root hub is matched by serial, which carries the
  # stable PCI address (bus names like usb1 depend on enumeration order),
  # plus speed, scoping it to the high-speed hub that low-speed dongles
  # enumerate under.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{serial}=="0000:02:00.0", ATTR{speed}=="480", ATTR{power/wakeup}="enabled"
    ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:02:00.0", ATTR{power/wakeup}="enabled"
  '';

  # Keep the TV's power in lockstep with the PC's: wake it on resume, put it
  # into standby on suspend. A consumer GPU has no HDMI-CEC, so the TV cannot
  # be driven over the HDMI cable the way a console does it; instead the
  # script publishes KEY_POWER to the TV's local MQTT broker (which stays
  # alive in its standby) over mutual TLS. It is standard-library-only, so a
  # bare python3 runs it -- nothing is added to systemPackages -- and it reads
  # its client certificate from /var/lib/vidaa (imperative host state).
  # KEY_POWER is a toggle, so the script is state-aware: it asks the TV for
  # its state first and never fires when the TV is already where it should
  # be. The directions budget differently: "on" retries for ~20 s to ride out
  # WiFi reassociation after resume, while "off" fails fast, since the suspend
  # waits on it with no timeout of its own. Powering the PC off is
  # deliberately not covered -- NixOS incidentally runs powerDownCommands at
  # shutdown too, but unordered against the WiFi teardown, so a TV that goes
  # dark with a poweroff is a bonus, never a promise. Full story and one-time
  # setup: pc/WAKING.md.
  powerManagement = {
    resumeCommands = "${pkgs.python3}/bin/python3 ${./toggle-tv.py} on";
    powerDownCommands = "${pkgs.python3}/bin/python3 ${./toggle-tv.py} off";
  };

  #### Networking ##############################################################

  networking = {
    hostName = "gaming";

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

  # Linux audio is layered:
  #
  # - ALSA: the kernel layer -- drivers for the sound hardware, plus a thin
  #   userspace API. Makes sound, but is bad at sharing: essentially one app(*)
  #   per device.
  # - PulseAudio: a protocol that defines how apps talk to a userspace sound
  #   server, which mixes many apps' streams onto one device.
  # - PipeWire: the modern implementation of the PulseAudio protocol. It also
  #   re-implements the ALSA userspace API, catching apps that talk ALSA
  #   directly.
  #
  # game (64- or 32-bit)
  #   │  speaks PulseAudio protocol (most) or ALSA API (some)
  #   ▼
  # PipeWire ──── rtkit grants its threads realtime priority
  #   ▼
  # ALSA kernel drivers ──▶ HDMI/DP audio via the GPU, or the Realtek jacks
  #
  # (*): Linux abstracts an audio device as a file, /dev/snd/pcmXXXX. To play
  #    sound, a program open()s that file and holds on to the handle -- and
  #    only one handle can be held at a time. "App" here means the holder of
  #    that handle.

  services.pipewire = {
    # Run PipeWire as THE sound server.
    enable = true;

    alsa = {
      # Catch apps that use the ALSA userspace API directly and redirect them
      # into PipeWire, instead of letting them grab the hardware exclusively.
      enable = true;

      # The same redirect shim in 32-bit, for the many Proton/Windows games and
      # older native titles that are 32-bit binaries -- the audio twin of the
      # 32-bit graphics libraries Steam pulls in.
      support32Bit = true;
    };

    # Speak the PulseAudio protocol on the PulseAudio socket. Most software
    # (Steam, SDL, most game engines) targets PulseAudio and works unchanged,
    # never noticing PipeWire answered. No actual PulseAudio runs here.
    pulse.enable = true;
  };

  # RealtimeKit: a D-Bus broker that grants realtime CPU priority to
  # unprivileged processes, within safety limits. PipeWire's mixer thread must
  # produce the next few milliseconds of samples on time, every time -- late
  # scheduling is audible as crackles. On a box that keeps its CPU pinned by
  # games, this is what keeps audio glitch-free.
  security.rtkit.enable = true;

  #### Steam + gamescope #######################################################

  programs.steam = {
    # Also pulls in Proton and controller udev rules. Enable Proton for all
    # titles in Steam: Settings > Compatibility, after first login.
    enable = true;

    # Big Picture's "Power > Switch to Desktop" only does anything in SteamOS
    # mode (the -steamos3 flag below; without it the client still draws the
    # menu entry -- that part is gated merely on "running inside gamescope" --
    # but the click execs nothing and the "Switching to Desktop" spinner hangs
    # forever; steam-for-linux #11241). In SteamOS mode it execs the SteamOS
    # helper `steamos-session-select`, then waits for the surrounding session
    # to tear Steam down and start a desktop. No desktop exists on this box,
    # so provide the helper and make it mean "quit Steam gracefully":
    # `steam -shutdown` (one of the few client flags Valve documents) saves
    # state and exits the client, which ends the gamescope session and drops
    # back to the TTY. The script must be visible INSIDE Steam's FHS sandbox
    # -- the client is what invokes it -- hence extraPackages, not
    # environment.systemPackages.
    extraPackages = [
      (pkgs.writeShellScriptBin "steamos-session-select" ''
        exec steam -shutdown
      '')
    ];

    # Provides the `steam-gamescope` command: gamescope running directly on
    # DRM/KMS with Steam Big Picture inside it.
    gamescopeSession = {
      enable = true;

      args = [
        # The TV is a Hisense 100U7KQ: 3840x2160, and accepts 4K@144 Hz with
        # VRR (FreeSync Premium Pro, 48-144 Hz range) over HDMI 2.1. Game mode
        # must be enabled on the TV's input for VRR/144 to be offered.
        "-W"
        "3840"
        "-H"
        "2160"
        "-r"
        "144"
        "--adaptive-sync"
        "--hdr-enabled"

        # Spawn mangoapp (from the mangohud package in systemPackages) inside
        # the session: the performance overlay SteamOS uses. gamescope
        # composites it on top of whatever is on screen, so it covers every
        # game -- any graphics API, native or Proton, 32- or 64-bit -- and
        # the Big Picture UI itself, with no per-game launch options.
        "--mangoapp"
      ];

      # Capability flags that SteamOS's own session exports; the
      # steam-gamescope wrapper `export`s these before exec'ing gamescope, so
      # gamescope, mangoapp and the client all inherit them. They advertise
      # the mangoapp overlay to the client, which then shows a "Performance
      # Overlay Level" slider in Quick Access (the "..." button >
      # Performance): level 0 (off) up to 4, from a bare FPS number to the
      # full panel -- CPU/GPU load and temperature, RAM/VRAM, frametime
      # graph. Same recipe as ChimeraOS/Bazzite, which pair these with
      # SteamOS mode (-steamos3 below).
      env = {
        STEAM_USE_MANGOAPP = "1";
        STEAM_MANGOAPP_PRESETS_SUPPORTED = "1";
        STEAM_MANGOAPP_HORIZONTAL_SUPPORTED = "1";
      };

      # Arguments to Steam itself. Setting this option REPLACES its default,
      # so the two stock entries (-tenfoot, -pipewire-dmabuf) must be restated.
      steamArgs = [
        # Starts the client straight into Big Picture.
        "-tenfoot"

        # Enables zero-copy PipeWire capture of the session (Remote Play, game
        # recording).
        "-pipewire-dmabuf"

        # Forces GPU-accelerated rendering of the client's web views
        # (steamwebhelper, an embedded Chromium), overriding the "Enable GPU
        # accelerated rendering in web views" toggle persisted in
        # ~/.local/share/Steam/config/config.vdf. Without acceleration, Big
        # Picture rasterizes 4K frames on the CPU -- a ~1 fps slideshow. The
        # flag is undocumented (Valve documents almost no client flags), but
        # verified on this box 2026-07-04: with the toggle off, launching with
        # the flag still yields a smooth UI. If a future client drops the flag,
        # it is silently ignored and the persisted toggle rules again.
        "-cef-force-gpu"

        # Declares the client to be running on SteamOS 3 (the Steam Deck's
        # OS). This is what arms the power menu's "Switch to Desktop" action:
        # the client only invokes `steamos-session-select` (the shim in
        # extraPackages above) in SteamOS mode; without the flag the click
        # execs nothing and the spinner hangs forever (steam-for-linux
        # #11241). Same recipe as ChimeraOS/Bazzite-style gamescope sessions.
        # Known tradeoff: SteamOS mode disables the Shift-Tab keyboard
        # shortcut for the in-game overlay; irrelevant here, the controller's
        # Guide button still opens it.
        "-steamos3"
      ];
    };
  };

  #### Auto-login + auto-launch ###############################################

  # Log larry in automatically on the virtual consoles: getty runs
  # `agetty --autologin larry`, which skips the password prompt but still runs
  # the full PAM session machinery (logind session on seat0, XDG_RUNTIME_DIR),
  # so the resulting shell is identical to one from a typed login. Local TTYs
  # only: SSH never passes through getty -- sshd authenticates by its own
  # rules (public keys, see Networking) and is unaffected. The account
  # password stays, solely as the sudo gate.
  services.getty.autologinUser = "larry";

  # Launch Steam from the auto-logged-in shell. loginShellInit is appended to
  # /etc/profile, which every login shell sources; three guards scope it to
  # exactly the boot-time console session:
  #
  # - tty1 only: SSH sessions run on pseudo-terminals (/dev/pts/N), and the
  #   other consoles (Ctrl-Alt-F2, ...) stay plain shells for maintenance.
  # - larry only: `sudo -i` on tty1 is also a login shell on tty1; without
  #   this guard it would launch a second Steam, as root.
  # - once per login: a nested `bash -l` inherits the marker variable and
  #   stays a plain shell.
  #
  # Deliberately NOT `exec`: the shell survives Steam exiting, so "Switch to
  # Desktop" (the shim above) lands on a logged-in tty1 prompt. Logging out of
  # that shell (Ctrl-D) makes getty respawn and auto-login again, relaunching
  # Steam: quit = shell, Ctrl-D = back to Big Picture. With `exec`, the
  # respawn would relaunch Steam instantly, turning "Switch to Desktop" into
  # "restart Steam".
  environment.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ] && [ "$USER" = larry ] && [ -z "$STEAM_AUTOLAUNCHED" ]; then
      export STEAM_AUTOLAUNCHED=1
      steam-gamescope
    fi
  '';
}
