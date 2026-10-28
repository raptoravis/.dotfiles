---
title: 'Distinguish zg port conflicts in the Windows installer'
type: 'bugfix'
ticket: ''
created: '2026-10-28'
status: 'built'
baseline_revision: '59fbb7a4818746c9ebc56e1aa2cac18853c89e30'
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

**Problem:** The Windows installer reports an MCP configuration conflict after zg successfully configures integrations but fails to bind an occupied server port. Its generic warning obscures which action failed.

**Approach:** Preserve zg output and distinguish occupied-port failures, explicit configuration conflicts, and other failures. Describe EADDRINUSE factually without claiming the port owner is a healthy zg daemon. Preserve target selection, install arguments, sequencing, and nonfatal continuation. This is a standalone fix.

</frozen-after-approval>

## Implementation Notes

- Use the oneshot route because the change affects a single small diagnostic block in install-windows.ps1.
- Existing macOS and Linux integration blocks already classify zg failures. Windows should use the same categories while retaining all diagnostics.
- BMad setup created _bmad locally before this fix; the initial working tree was clean.
- Implemented capture of merged zg output and immediate exit-code capture, preserving diagnostics and classifying EADDRINUSE separately from configuration and unknown failures.
- PowerShell parsing and five mocked integration scenarios passed: success, stdout port conflict, stderr port conflict, configuration conflict, and unknown failure. The mocks also verified install arguments and continued execution. No full bootstrap was run.
- Windows PowerShell 5.1 parser validation also passed. BMad setup is current, with no legacy leftovers or applicable artifact migrations; its generated setup files remain local and untracked.

## Plan Change Log

## Review Triage Log

- Quick review completed with no findings in the installer fix or standalone plan. No deferred findings.

## Verification

- Parse install-windows.ps1 with the PowerShell parser; expect no syntax errors.
- Execute only the extracted zg integration block with mocked zg outcomes: success, EADDRINUSE, configuration conflict, and unknown failure. Check output, warning classification, install arguments, and continued execution without running the full bootstrap.
- Run git diff --check; expect no whitespace errors.
