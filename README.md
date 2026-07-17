# nix

Nix setup for my working ([`mac/`](./mac/)) and gaming ([`pc/`](./pc/)) computers.

## Development environment

Starting from a fresh macOS computer:

### 1. Install Nix

Use the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer) — it handles the APFS volume creation, survives macOS updates, and ships an uninstaller:

```sh
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

Open a new terminal afterwards so the shell picks up the Nix environment.

### 2. Install the development environment

Clone this repo and install the [`mac/`](./mac/) environment into the user profile:

```sh
git clone https://github.com/larry0x/nix.git ~/workspace/larry0x/nix
cd ~/workspace/larry0x/nix
nix profile add .
```

Among everything else, this provides the Nix tooling used to work on this repo:

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
