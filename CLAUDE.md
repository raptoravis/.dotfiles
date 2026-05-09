# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow .wolf/OPENWOLF.md every session. Check .wolf/cerebrum.md before generating code. Check .wolf/anatomy.md before reading files.

# Dotfiles — AI Assistant Guide

A cross-platform dotfiles repo managed by [dotter](https://github.com/SuperCuber/dotter) (symlinks), [cargo-make](https://github.com/sagiegurari/cargo-make) (tasks), and [mise](https://github.com/jdx/mise) (runtimes). Forked from msetsma; current working tree at `D:\dev\.dotfiles` on Windows (also accessed from WSL via `/mnt/d/dev/.dotfiles`).

## Architecture

Unix-first. The core dev environment (zsh, neovim, CLI tools) targets unix; Windows reaches it via WSL2. Both platforms converge on the same `common/` configs.

```
macOS:    native apps (Ghostty, AeroSpace) --> unix backend (zsh, neovim, tmux)
Windows:  native apps (WezTerm, AHK)       --> WSL2 --> unix backend (zsh, neovim, tmux)
```

### Directory model

| Directory  | Purpose | Dotter package |
|------------|---------|----------------|
| `common/`  | Cross-platform base layer — shell, editors, dev tools, linters, wezterm, nushell | `common` |
| `macos/`   | macOS-only GUI apps (aerospace, ghostty, borders) | `mac` |
| `windows/` | Windows-only host integration (ahk, wsl, powershell) | `windows` |

### Platform detection

`common/zsh/platform.zsh` sets `PLATFORM` and boolean flags (`IS_MAC`, `IS_WSL`, `IS_LINUX`) used by every shell config. Gates behavior with `(( IS_MAC ))` / `(( IS_WSL ))`. Key abstractions:

- **Clipboard**: `_clip` function (wraps `pbcopy` / `clip.exe` / `xclip`)
- **URL/file open**: `open` alias (wraps `open` / `wslview` / `xdg-open`)
- **Credentials**: macOS Keychain `security` CLI vs `~/.config/databricks/.env-{env}` files
- **PATH**: `/opt/homebrew/bin` (mac) vs standard linux paths + optional linuxbrew

### Dotter package selection

Dotter picks packages by reading `.dotter/<hostname>.toml` first; if absent it falls back to `.dotter/local.toml` (gitignored, machine-local — auto-created by the install scripts). Each toml contains a `packages = [...]` array referenced against the `[<package>.files]` sections in `.dotter/global.toml`.

| Package | Symlinks from | Used on |
|---------|---------------|---------|
| `common` | `common/*` | All platforms |
| `mac`    | `common/bottom` (mac path) + `macos/*` | macOS |
| `linux`  | `common/bottom` (linux path) | Linux/WSL2 |
| `windows`| `windows/*` (wsl, ahk, powershell) | Windows host |

## Setup & common commands

### Bootstrap (preferred — does more than `cargo make init`)

The top-level `install-{mac,linux,windows}.{sh,ps1}` scripts are the source of truth for first-time setup. They install OS packages, Rust/Cargo tools, npm CLIs, agent skills, the rtk hook, and finally run `dotter -v`.

```bash
# macOS
./install-mac.sh

# Linux / WSL2 (run inside WSL on Windows)
./install-linux.sh

# Windows host (PowerShell — Scoop + native GUI configs)
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

`cargo make init` is the older path — it still works for the package-install steps but does not handle agent skills, rtk, or npm CLIs.

### Daily

```bash
cargo make update         # brew/apt + rustup + cargo + mise
cargo make check-outdated # dry-run
update                    # zsh function — same as above

dotter -v                 # re-apply symlinks after editing global.toml or adding files
rld                       # reload zsh (custom function)
```

### Sanity checks before commit

There are no test suites. The repo has linter configs but no aggregate `lint` task — run the relevant tool for the files you touched:

```bash
shellcheck install-linux.sh install-mac.sh             # bash scripts
ruff check . && ruff format --check .                  # python (config: common/linters/ruff.toml)
stylua --check common/nvim/                            # lua (config: common/linters/stylua.toml)
```

## Cross-CLI agent skills (non-obvious — read before adding skills)

`install-{mac,linux,windows}` install a curated set of portable skills (handoff, karpathy, excalidraw-diagram, html-ppt, frontend-design, understand-anything) and link each into **all four** CLI roots:

- `~/.agents/skills/`
- `~/.claude/skills/`
- `~/.codex/skills/` (honors `$CODEX_HOME`)
- `~/.config/opencode/skills/`

The three install scripts must stay symmetric. To add a new skill, edit all three scripts:

1. `clone_or_pull` / `CloneOrPull` the upstream repo into `$PLUGIN_CACHE` (`~/.cache/dotfiles/agent-plugins`).
2. `link_skill` / `LinkSkillToRoots` to fan it out to all four roots in one call.
3. If the skill ships slash-command markdown that Codex can use as `/foo`, copy it into `~/.codex/prompts/` in the "Codex prompts" block.

Claude-Code-only marketplace plugins (those that need `hooks/hooks.json`, `commands/`, etc.) are not portable — they live in `common/claude/settings.json` instead and are wired by dotter.

## Key files

| File | Role |
|---|---|
| `.dotter/global.toml` | Symlink mappings, sectioned by package (`[common.files]`, `[mac.files]`, ...) |
| `.dotter/local.toml` | Machine-local `packages = [...]` selection (gitignored) |
| `Makefile.toml` | Cargo-make setup/install tasks (legacy bootstrap path) |
| `Makefile.utils.toml` | Daily utility tasks (pkg mgmt, backup, doctor) |
| `install-{mac,linux,windows}.{sh,ps1}` | Authoritative bootstrap — keep cross-CLI skill blocks symmetric |
| `common/zsh/platform.zsh` | Platform detection — sourced first by `.zshrc` |
| `common/zsh/.zshrc` | Main zsh config (platform-gated PATH, brew, fzf, oh-my-zsh) |
| `common/zsh/aliases.zsh` | Aliases with `_clip` / `open` abstractions |
| `common/zsh/functions/` | Autoloaded zsh functions |
| `Brewfile` | Homebrew packages (macOS) |
| `uv-tools.txt` | uv-managed Python tools (consumed by all three install scripts) |

## Conventions

- **Unix-first**: write shell for unix; gate platform-specific code with `(( IS_MAC ))` / `(( IS_WSL ))`.
- **Use abstractions, not raw commands**: `_clip` (not `pbcopy`), `open` alias (not the `open` binary).
- **Many small files > few large files** — especially for zsh functions (one function per file under `functions/`).
- **Naming**: functions `lower_snake_case` (`git_fzf_checkout`); aliases lowercase abbreviations (`gfc`, `lt`, `db`); scripts `snake_case.sh`.
- **Comments**: functional, not verbose.
- **Performance-focused tooling**: prefer Rust replacements (eza, bat, ripgrep, fd, bottom).

## Adding a new tool config

1. Create directory under `common/`, `macos/`, or `windows/` as appropriate.
2. Add entry to `.dotter/global.toml` under the matching `[<package>.files]` section.
3. Add installation to `Makefile.toml` AND the three `install-*` scripts (with platform aliases as needed).
4. Run `dotter -v` to apply.

## Modifying zsh config

Edit `common/zsh/{.zshrc,aliases.zsh,platform.zsh,functions/}`. Files symlink to `~/.config/zsh/` (ZDOTDIR is set in `~/.zshenv` by the install scripts). Reload with `rld`.

## Don't assume

- Which platform the user is currently on (check `IS_MAC`/`IS_WSL` or ask).
- That all tools are installed (user may be mid-setup).
- That `pbcopy`, `open`, or `security` are available — use the abstractions.
- That a hostname-named `.dotter/*.toml` exists — `local.toml` is the documented fallback.

## Troubleshooting

```bash
# Symlinks not applying
cd ~/.dotfiles && dotter -v

# WSL2 line-ending breakage (\r in shell scripts)
git add --renormalize .

# Cargo-make platform detection
rustc -Vv | grep host
cargo make --print-only <task-name>
```

PATH includes (platform-dependent): `/opt/homebrew/bin` (mac), `/home/linuxbrew/.linuxbrew/bin`, `~/.cargo/bin`, `~/.local/bin`.

## Agent skills (repo-internal)

- **Issue tracker**: markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.
- **Triage labels**: 5-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.
- **Domain docs**: `CONTEXT.md` and `docs/adr/` at the repo root, created lazily by `/grill-with-docs`. See `docs/agents/domain.md`.
