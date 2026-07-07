# gaming

Minimalist NixOS gaming machine

## Spec

| Part        | Model                               | Purchase Date | Vendor          |          Price |
| ----------- | ----------------------------------- | ------------- | --------------- | -------------: |
| Motherboard | ASRock A520M-ITX/AC                 | 2022-11-11    | pccomponents.pt |       143.07 € |
| CPU         | AMD Ryzen 9 5900X                   | 2021-09-19    | pccomponents.pt |       534.58 € |
| CPU Cooler  | be quiet! Pure Loop 3               | 2026-06-28    | amazon.es       |        80.65 € |
| RAM         | Corsair Vengeance DDR4 3600 2x16G   | 2021-09-19    | pccomponents.pt |       180.74 € |
| GPU         | Gigabyte GeForce RTX 3080 Ti Vision | 2021-09-19    | pcdiga.com      |     1,599.90 € |
| SSD         | Samsung 980 Pro 1TB PCIe NVMe M.2   | 2022-05-11    | pccomponents.pt |       135.95 € |
| PSU         | CORSAIR SF850                       | 2026-06-28    | amazon.es       |       177.00 € |
| Case        | Thermaltake TR100                   | 2026-06-28    | amazon.es       |       167.07 € |
| **Total**   |                                     |               |                 | **3,018.91 €** |

## Development environment

Starting from a fresh macOS computer:

### 1. Install Nix

Use the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer) — it handles the APFS volume creation, survives macOS updates, and ships an uninstaller:

```sh
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

Open a new terminal afterwards so the shell picks up the Nix environment.

### 2. Install the language server, linters, and formatter

```sh
nix profile add \
  nixpkgs/nixos-26.05#nixd \
  nixpkgs/nixos-26.05#nixfmt \
  nixpkgs/nixos-26.05#statix \
  nixpkgs/nixos-26.05#deadnix
```

- `nixd`: language server — completion, hover docs, and diagnostics for NixOS options
- `nixfmt`: the official formatter
- `statix`: lints for Nix anti-patterns
- `deadnix`: finds dead code, such as unused bindings and lambda arguments

### 3. Set up VSCode

Install the [Nix IDE](https://marketplace.visualstudio.com/items?itemName=jnoortheen.nix-ide) extension — the exact identifier is `jnoortheen.nix-ide`, beware of lookalikes — and point it at nixd in `settings.json`:

```json
{
  "nix.enableLanguageServer": true,
  "nix.serverPath": "/Users/<you>/.nix-profile/bin/nixd"
}
```

### 4. Run the checks

```sh
just fmt
just lint
just test
```

## Installation

1. Insert the bootable USB drive. Press the PC power button.

2. Upon seeing the ASRock logo, press `F12`/`Del` to enter UEFI menu, or `F11` to select boot drive.

3. In the boot menu, select `the NixOS <version> (Linux LTS)` one. This refers to the version of the Live CD, not what will be installed.

4. Once TTY appears, connect to WiFi:

   ```sh
   sudo nmcli device wifi list
   sudo nmcli device wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
   ```

   Check connection works:

   ```sh
   ping -c 3 nixos.org
   ```

   Give the user a password, so we can SSH into the host:

   ```sh
   passwd
   ```

   Find the host's IP:

   ```sh
   ip addr show
   ```

   Note: it's recommended to assign this machine a static LAN IP address in the router's "DHCP Reservation" settings.

   On the Mac, SSH into the server:

   ```sh
   ssh nixos@192.168.x.x
   ```

5. Inspect the hardware:

   ```sh
   lscpu
   lsmem
   lsblk
   lspci | grep -i nvidia
   ```

6. Check SSD health:

   ```sh
   sudo nix-shell -p nvme-cli --run "nvme smart-log /dev/nvme0"
   sudo nix-shell -p smartmontools --run "smartctl -a /dev/nvme0"
   ```

   Give the output to Claude and ask for opinion.

7. Wipe (if it's a used SSD), partition, format, and mount the SSD.

   Wiping:

   ```sh
   sudo wipefs -a /dev/nvme0n1
   sudo sgdisk --zap-all /dev/nvme0n1
   ```

   Partitioning:

   ```sh
   sudo parted /dev/nvme0n1 -- mklabel gpt
   sudo parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
   sudo parted /dev/nvme0n1 -- set 1 esp on
   sudo parted /dev/nvme0n1 -- mkpart root ext4 1GiB 100%
   ```

   Formatting:

   ```sh
   sudo mkfs.fat -F 32 -n boot /dev/nvme0n1p1
   sudo mkfs.ext4 -L nixos /dev/nvme0n1p2
   ```

   Mounting:

   ```sh
   sudo mount /dev/disk/by-label/nixos /mnt
   sudo mkdir -p /mnt/boot
   sudo mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
   ```

8. Clone this repo, regenerate `hardware-configuration.nix` (replacing the placeholder), and install NixOS:

   ```sh
   git clone https://github.com/larry0x/gaming
   cd gaming
   sudo nixos-generate-config --root /mnt --show-hardware-config | tee hardware-configuration.nix
   sudo nixos-install --flake .#gaming --no-root-passwd
   ```

9. Reboot:

   ```sh
   sudo reboot
   ```

10. A few things after the first time boot:

    Change password:

    ```sh
    passwd
    ```

    Connect WiFi (not `nmcli`, which is only available in the installer):

    ```sh
    iwctl device list
    iwctl station <device> connect <SSID>
    ```

    Bring up Tailscale:

    ```sh
    sudo tailscale up
    ```

    On the Mac, the computer becomes accessible with:

    ```sh
    ssh larry@gaming
    ```

## Update

```sh
nix flake update
just rebuild
```
