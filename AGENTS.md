# Repository Guidelines

## Project Structure & Module Organization

This is a unix-first dotfiles repository with platform-specific host layers.
`common/` contains shared shell, editor, terminal, CLI, linter, and agent
configuration used across machines. `macos/` contains macOS-only GUI and window
manager settings. `windows/` contains Windows host assets such as PowerShell,
AutoHotkey, bundled utilities, and WSL configuration. `.dotter/` defines symlink
deployment. `docs/` holds supporting notes, while `install-*.sh` and
`install-windows.ps1` are the bootstrap entry points.

## Build, Test, and Development Commands

Use `cargo make help` for the short command list and `cargo make info` for the
full task inventory. `cargo make init` performs the normal setup flow. Use
`cargo make dotfiles-check` to validate Dotter configuration without deploying,
and `cargo make deploy` to apply symlinks. Platform bootstraps are
`./install-mac.sh`, `./install-linux.sh`, and
`powershell -ExecutionPolicy Bypass -File .\install-windows.ps1`.

## Coding Style & Naming Conventions

Keep changes scoped to the relevant platform or shared layer. Prefer
lowercase, hyphenated names for shell scripts and task names, matching existing
patterns such as `install-linux.sh` and `dotfiles-check`. Lua uses Stylua
settings from `common/linters/stylua.toml`: 4-space indents, 120 columns, Unix
line endings. Python tooling follows `common/linters/ruff.toml`: 4-space
indents, 120 columns, single quotes where practical. Keep scripts idempotent and
safe to rerun.

## Testing Guidelines

There is no dedicated test suite. Validate changes with the narrowest relevant
command: `cargo make dotfiles-check` for Dotter mappings, `bash -n
install-linux.sh install-mac.sh` for shell syntax, and PowerShell parser checks
for `install-windows.ps1`. For editor or shell config edits, test in the target
platform before merging.

## Commit & Pull Request Guidelines

Recent history uses short Conventional Commit-style prefixes when useful, such
as `docs:`, `install:`, and `claude:`; otherwise brief `update` commits appear.
Prefer descriptive messages that name the affected area, for example
`install: sync cross-cli skill roots`. PRs should explain the platform impact,
list validation commands run, and call out any manual setup or migration steps.

## Security & Configuration Tips

Do not commit secrets, tokens, private keys, or machine-local credentials.
Review bundled Windows binaries and install-script network changes carefully.
When editing agent, Claude, Codex, or OpenCode setup, keep platform behavior
consistent across macOS, Linux/WSL, and Windows unless a platform-specific
exception is documented.
