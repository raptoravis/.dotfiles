---
title: 'Enable Claude HUD statusline during bootstrap'
type: 'bugfix'
ticket: ''
created: '2026-10-28'
status: 'built'
baseline_revision: 'beea3b7cad07fbf6375a5f1bf9e4eb84dd4d8056'
route: 'oneshot'
route_source: 'auto'
risk: 'low'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The installers deploy Claude HUD assets and install the plugin but do not populate statusLine. A fresh installation consequently has no context display until manual setup.

**Approach:** Extend the existing settings merge in install-windows.ps1, install-linux.sh, and install-mac.sh to add a command pointing to the deployed launcher when no command is configured. Preserve existing commands and unrelated settings; honor the selected Claude configuration directory and keep reruns idempotent.

</frozen-after-approval>

## Implementation Notes

- One-shot: three matching configuration blocks need a small, mechanical addition. No dependencies or plugin changes required.
- Updated all three bootstrap settings merges to fill a missing statusLine command using the selected configuration directory, with slash normalization for Git Bash and quoted paths containing spaces. Existing statusline commands remain unchanged.
- Verification passed: 12 scenarios across all three extracted configuration blocks, with a second run confirming no settings rewrite. Cases cover absent files, empty settings, existing permissions/environment/plugin settings, and an existing custom statusline.
- The generated Windows command ran through Git Bash against the installed plugin and rendered Opus plus 12% context from a configuration path containing spaces. Both Bash scripts and the PowerShell script passed syntax checks; git diff --check passed. Full bootstrap was not run because it installs and deploys unrelated system configuration.
- Review correction: use shell single-quote escaping rather than JSON quoting for launcher paths. Repeated all 12 scenarios and idempotency checks; nine generated commands executed successfully with spaces, dollar signs, backticks, command-substitution text, and apostrophes in the configuration path. The real HUD rendered model and context through the corrected Windows command. Fresh syntax and whitespace checks passed.

## Plan Change Log

## Review Triage Log

- medium / patch: JSON quoting allowed shell expansion in launcher paths. Confirmed from generated double-quoted commands; replaced with single-quote escaping and verified literal special-character paths through Git Bash. No findings deferred.

## Verification

- Extract and execute each installer configuration block against temporary homes: missing settings, existing settings, existing statusline, and repeat runs.
- Run the generated Windows command through Git Bash with sample Claude stdin; expect model and context output.
- Run PowerShell parser, bash syntax validation, and git diff --check.
