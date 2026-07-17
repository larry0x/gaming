# mac

My macOS development environment: a single Nix profile providing every development tool, so that a fresh Mac replicates the full setup with one command.

Layering rules:

- Everything development-related lives here, in Nix.
- Homebrew is for non-development software only, e.g. GUI apps (casks).
- Stock macOS tools stay stock — notably git, which ships with the Xcode Command Line Tools.
- Claude Code uses its own self-updating native installer.
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

- `cargo` is a thin shim that accepts rustup-style `cargo +nightly …` invocations: the `+toolchain` argument is dropped, which is correct because rustfmt in this environment _is_ the nightly one, and everything else runs on the stable toolchain.
- mdbook and mdbook-mermaid come stock from nixpkgs; mdbook-katex is built from crates.io (nixpkgs' version is stale). The preprocessors may print a cosmetic "built against version X" warning when their locked mdbook libraries trail the mdbook binary — math and diagrams render fine regardless.
- The docker daemon is colima (`colima start`); the docker CLI, compose, and buildx come from this flake, with the compose/buildx plugins linked into `~/.docker/cli-plugins/`.
- coreutils are the GNU ones, unprefixed: they deliberately shadow the stock BSD `ls`, `date`, `stat`, etc.
