# mac

My macOS development environment: a single Nix profile providing every development tool, so that a fresh Mac replicates the full setup with one command.

Layering rules:

- Everything development-related lives here, in Nix.
- Homebrew is for non-development software only, e.g. GUI apps (casks).
- Stock macOS tools stay stock — notably git, which ships with the Xcode Command Line Tools.
- Coding agents — Claude Code and OpenCode — are deliberately installed with their official installer scripts, not from nixpkgs. Rationale: they release near-daily, and only native installs self-update; a nixpkgs install stays frozen at whatever `flake.lock` pinned, and OpenCode's nixpkgs wrapper disables its auto-updater outright (`OPENCODE_DISABLE_AUTOUPDATE`). Their binaries live in `~/.local/bin` and `~/.opencode/bin`, put on `PATH` by `~/.zshrc`.
- No language-version managers (rustup, nvm, corepack): toolchains are pinned by `flake.lock`.

## Install

```sh
just mac-add
```

This installs `packages.aarch64-darwin.default` — one big `buildEnv` defined in [`env.nix`](./env.nix) — into the user profile. Make sure `~/.nix-profile/bin` is prepended to `PATH` ahead of Homebrew in `~/.zshrc`.

## Update

```sh
just update        # bump the flake inputs
just mac-upgrade   # rebuild the profile from the flake
```

Roll back with `nix profile rollback`.

## Notes

- mdbook and mdbook-mermaid come stock from nixpkgs; mdbook-katex is built from crates.io (nixpkgs' version is stale). The preprocessors may print a cosmetic "built against version X" warning when their locked mdbook libraries trail the mdbook binary — math and diagrams render fine regardless.
- The docker daemon is colima (`colima start`); the docker CLI, compose, and buildx come from this flake, with the compose/buildx plugins linked into `~/.docker/cli-plugins/`.
- No GNU coreutils: the stock BSD userland (`ls`, `date`, `stat`, etc.) stays as-is, with Rust replacements (bat, eza, dust, ripgrep) aliased over the common ones in interactive shells via `~/.zshrc`.
