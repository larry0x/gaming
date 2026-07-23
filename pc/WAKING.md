# Waking

The goal is the console experience: one button press on a handheld input device wakes the entire setup — both the machine and the television — with nothing else to reach for. On a games console that press is on the controller; here it is a keypress on the keyboard, and it has to bring up _both_ the gaming PC (from suspend) and the TV (from standby), so that a single key from the couch lands you back in Steam Big Picture on a lit screen. The mirror of that press matters just as much: when the PC goes to sleep, the TV should go dark with it, with nothing else to switch off.

That splits into two independent problems, taken in turn below: waking the **PC** from suspend on a keypress, and having the PC hold the **TV**'s power in lockstep with its own — waking it on resume, putting it into standby on suspend. The declarative pieces live in [`configuration.nix`](./configuration.nix) and [`toggle-tv.py`](./toggle-tv.py); this document is the reasoning behind them, the one-time setup a fresh install must redo by hand, and the alternatives tried and abandoned along the way.

## Waking the PC from suspend

Both peripherals connect through their **2.4 GHz USB receivers**, and the keyboard's is the one that wakes the machine. From a keypress, the chain is:

1. The keyboard's receiver — a USB HID[^hid] device on a private radio link — signals **USB remote wakeup**. The kernel armed that capability automatically, because the receiver (`3554:fa0a`) declares the keyboard boot protocol.
2. The signal has to travel up the USB tree, and every hop on the way must have `power/wakeup` enabled for it to reach the platform: the root hub, then the xHCI[^xhci] PCI function whose PME[^pme] raises the ACPI[^acpi] wake event. Both belong to the chipset xHCI at PCI `0000:02:00.0`, and the `services.udev.extraRules` in `configuration.nix` arm them. The PCI-function hop is mandatory — disabling it severs wake entirely — and the root-hub rule is scoped by `speed==480` so only the high-speed hub the low-speed dongles sit under is armed, not its noisier SuperSpeed sibling.
3. The board leaves S3[^s3] and the system resumes.
4. The `nvidia-resume` service restores the video memory it saved on the way down (`hardware.nvidia.powerManagement.enable`). Without it the GPU comes back with VRAM cleared, gamescope's page-flip never completes ("Flip event timeout" in the kernel log), and the screen stays dark even though the system is up underneath (SSH still works).
5. gamescope is back on the panel — and the same resume moment kicks off waking the TV, below.

### Diagnostics

If wake ever stops working, the useful probes are:

```sh
cat /sys/power/mem_sleep                       # which sleep state (expect [deep])
grep -H . /sys/bus/usb/devices/*/power/wakeup  # which USB hops are armed
cat /proc/acpi/wakeup                          # the xHCI (PTXH) row must be enabled
```

On this board the xHCI logs a cosmetic `xHC error in resume, USBSTS 0x401, Reinit` on every resume and resets both root hubs; that is harmless, but it does mean `wakeup_count` is a useless witness here — use the `/sys/firmware/acpi/interrupts/gpe*` counters instead.

### Abandoned solutions

- **Bluetooth.** Both peripherals also speak Bluetooth, and it was the first approach — but it is incompatible with suspend here. A BLE[^ble] keyboard advertises whenever it is powered but unconnected, including right after the disconnect that suspending the machine itself performs, and the kernel counts any advertisement from a bonded HID device as a wake request. The result was a PC that woke itself a second or two after every suspend, for as long as the keyboard was switched on. Bluetooth is now disabled outright (`boot.blacklistedKernelModules = [ "btusb" ]`).
- **The controller as the waker.** The X20's 2.4 GHz receiver cannot wake the PC at all — it enumerates as a vendor-class Xbox-360 gamepad (`045e:028e`) whose USB descriptor omits the remote-wakeup capability, so the kernel never even creates a `power/wakeup` control for it. The controller is a one-way device here; the keyboard is the waker.

## Powering the TV with the PC

The TV is a Hisense 100U7KQ running VIDAA OS, driven over its own network control channel by [`toggle-tv.py`](./toggle-tv.py); the hooks in `configuration.nix` run it with `on` on every resume and with `off` on the way into every suspend. From either trigger, the chain is:

1. The script opens a TLS[^tls] connection to the TV's **MQTT[^mqtt] broker at `192.168.1.74:36669`**, which VIDAA keeps alive even in standby. The broker demands **mutual TLS**, so the script presents the client certificate embedded in the VIDAA Android app (`CN=VidaaAppAndroidV01`); the TV's own server certificate is self-signed and left unverified.
2. It completes the MQTT handshake with **per-connection credentials**. The username and password are not static — they are regenerated each time by an algorithm reverse-engineered from the app's `libmqttcrypt.so` (the `PATTERN`/`SUFFIX`/`XOR` constants in `toggle-tv.py`); static credentials are refused with `CONNACK 5 (not authorised)`. No pairing token is sent: the credentials plus the certificate are the whole of the authorization.
3. It subscribes to the TV's state topic — the exact `/remoteapp/mobile/broadcast/ui_service/state`, because the old broker (mosquitto 1.4.2) does not honour a `#` wildcard there — and asks the TV for its power state.
4. The gate: `KEY_POWER` is a toggle, so the script publishes it only when the TV is not already in the intended state — a TV already where it should be is never flipped out of it. A standby TV answers the query with silence, which the two directions read oppositely. Going `on`, silence is the standby signature, so the key is sent; going `off`, only an explicit on-state (any `statetype` other than `fake_sleep_0`) is met with the key, and silence means do nothing — a blind toggle there could wake a TV that was off all along.
5. The panel comes on — landing on the PC's input — or goes dark, matching the machine.

The script is standard-library-only — it hand-rolls the little MQTT it needs — so a bare `python3` runs it with nothing added to `systemPackages`.

The two directions also budget their patience differently. `on` runs right after resume, when WiFi is still reassociating, so it retries the connection for some twenty seconds. `off` runs as the start phase of systemd's `sleep-actions` unit, which the suspend waits on with no timeout of its own, so it fails fast instead — two attempts, then it lets the machine sleep with the TV untouched. Powering the PC _off_ is deliberately not covered: NixOS happens to run the same `off` command at shutdown as well, but unordered against the WiFi teardown, so a TV that goes dark with a poweroff is a bonus, never a promise.

### One-time imperative setup

None of this is reproduced by `nixos-rebuild`; a fresh install must redo it by hand, in three places.

#### On the PC

- **Install the client certificate.** Place the VIDAA app's client certificate and key at `/var/lib/vidaa/vidaa_client.pem` and `/var/lib/vidaa/vidaa_client.key`, owned by root and `chmod 600`. These are **never committed** — a private key, and copyrighted app material. Extract them from the VIDAA Android APK (`com.universal.remote.multi`, e.g. from APKMirror), whose keystore is at `res/raw/client_mobile_android.p12`:

  ```sh
  sudo mkdir -p /var/lib/vidaa
  P12=res/raw/client_mobile_android.p12
  PW=186e990688070325a1c4b0ce275d2388   # the app's fixed keystore password
  openssl pkcs12 -legacy -in "$P12" -clcerts -nokeys -passin pass:$PW -out vidaa_client.pem
  openssl pkcs12 -legacy -in "$P12" -nocerts  -nodes -passin pass:$PW -out vidaa_client.key
  sudo install -m600 -o root -g root vidaa_client.pem vidaa_client.key /var/lib/vidaa/
  ```

  The `-legacy` flag is required — the keystore uses RC2-40, which OpenSSL 3 gates behind it. The extracted certificate's subject must be `CN=VidaaAppAndroidV01`.

- **Pair once.** Pairing was done out of band with [`pyvidaa`](https://github.com/warrenrees/pyvidaa) (`tv auth pair`, entering the PIN shown on the TV). It registers this client's identity on the TV, which the TV then remembers; the script reuses the same MAC-derived client-id and needs no stored token afterwards. `pyvidaa` is deliberately _not_ installed on this machine — keep it only as the re-pair tool to reach for if a TV factory-reset ever de-authorizes us.

#### On the router

- **Reserve the TV's address.** Give the TV a DHCP reservation for `192.168.1.74`, so the address hard-coded in `toggle-tv.py` stays valid.

#### On the TV

- **Enable "last accessed source".** In the TV menu: Settings → System → Advanced Settings → Default Startup Page → "Last Accessed Source". This makes the TV power on to the PC's HDMI input rather than the VIDAA home screen.

### Fragility

This path leans on reverse-engineered, undocumented behaviour, so expect it to need occasional care:

- The client certificate expires in **2034**; a new one would have to be extracted from a then-current app.
- A VIDAA firmware update that changes the MQTT auth protocol (the app's "protocol version" thresholds) would break credential generation. The fix is to update the algorithm constants in `toggle-tv.py`, or re-pair with an updated `pyvidaa`.
- If the TV is factory-reset, re-pair with `pyvidaa` as above.

### Testing

With the certificate in place, run the script directly from the repo checkout on the PC:

```sh
sudo python3 pc/toggle-tv.py on   # or off
```

`on` with the TV in standby prints `TV asleep, sent KEY_POWER` and the set comes on in a few seconds; run it again with the TV on and it prints `TV already on, nothing to do` without toggling it off. `off` mirrors it: `TV on, sent KEY_POWER` puts the set into standby, and a second run reports `TV already off, nothing to do`. End to end: `sudo systemctl suspend` (over SSH) or Steam → Sleep with the TV on — the TV should go dark with the machine — then wake the PC with a keypress, and the TV should power back on by itself. Worth checking once is the safety case: switch the TV off with its remote while the PC is up, suspend, and confirm the suspend leaves the TV asleep. The script's output lines land in `journalctl -u sleep-actions.service`, the unit whose start phase runs the suspend hook and whose stop phase runs the resume hook.

### Abandoned solutions

- **HDMI-CEC.**[^cec] The way a console powers a TV on is CEC "One Touch Play" over the HDMI cable. It is unavailable here because no consumer discrete GPU — NVIDIA, AMD, or Intel — wires the HDMI CEC pin, so there is nothing for the driver to drive. (A USB-CEC adapter would add it; see below.)
- **Wake-on-LAN.** The obvious network wake. This TV is WiFi-only and does not honour magic packets in standby — broadcast, subnet-directed, port 9, and unicast were all tried and none woke it. (The VIDAA phone app wakes it over the LAN by the MQTT channel above, not by Wake-on-LAN.)
- **A Pulse-Eight USB-CEC adapter (~€50).** A small box that adds real CEC over USB; it would wake the TV _and_ switch its input robustly, immune to VIDAA firmware churn, and could even make the TV remote wake the PC. Rejected only because the MQTT route costs nothing and needs no extra hardware — worth revisiting if the software path ever becomes too brittle.
- **`changesource` to select the input.** Publishing a source change looked like it might wake-and-switch in one step, but it cannot wake a sleeping TV and will not switch to a signal-less input (the PC's HDMI is dark until the PC is outputting). Superseded entirely by the TV's own "last accessed source" setting.
- **Running `pyvidaa` at runtime.** The `pyvidaa` library implements all of this and was invaluable for the reverse-engineering, but shipping it as a runtime dependency — a whole Python package tree on a minimalist box — was not worth it when the wake itself is a few dozen lines of standard library. It is kept only as the re-pair tool (above).
- **A blind `KEY_POWER` press.** The simplest possible script would just send the key — but `KEY_POWER` is a toggle: on resume it would switch _off_ a TV that is already on, and on suspend it could wake a TV that was already off. The state gate in step 4 is why the script is a little longer.

[^ble]: Bluetooth Low Energy — the low-power Bluetooth variant used by wireless peripherals.
[^hid]: Human Interface Device — the device class for keyboards, mice, and gamepads.
[^xhci]: eXtensible Host Controller Interface — the USB host-controller standard.
[^pme]: Power Management Event — the PCI signal a device raises to request a system wake.
[^acpi]: Advanced Configuration and Power Interface — the firmware/OS standard for power management, including which devices may wake the system.
[^s3]: S3 — the ACPI "Suspend-to-RAM" sleep state, in which the machine's state is held in still-powered RAM while the rest of the hardware is largely powered off.
[^cec]: Consumer Electronics Control — the HDMI side-channel that lets linked devices control each other (e.g. a console powering the TV on).
[^mqtt]: Message Queuing Telemetry Transport — a lightweight publish/subscribe messaging protocol.
[^tls]: Transport Layer Security — the standard protocol for encrypted, authenticated network connections.
