# Windows Changes

## Disable 'Microsoft Hotkeys'

To disable the annoying hotkeys that open microsft apps like copilot, teams, linkedin, etc
run this command as admin in a command prompt.

```cmd
REG ADD HKCU\Software\Classes\ms-officeapp\Shell\Open\Command /t REG_SZ /d rundll32
```

## PostgreSQL over Tailscale

`install-windows.ps1` installs Tailscale. Sign in once on each machine that
needs database access. Only the Windows machine hosting PostgreSQL needs to run
the database setup script from an elevated PowerShell prompt:

```powershell
.\windows\scripts\setup-postgresql.ps1
```

The setup installs PostgreSQL 18 as an auto-starting Windows service, enables
SCRAM authentication for Tailscale addresses, and limits the Windows Firewall
rule to the Tailscale IPv4 and IPv6 ranges. Its generated superuser password is
stored with Windows DPAPI under `%LOCALAPPDATA%\dotfiles\postgresql`; it is not
stored in this repository.

To migrate a project database, keep its source `DATABASE_URL` in its backend env
file and run:

```powershell
.\windows\scripts\migrate-postgresql-project.ps1 `
  -SourceEnvFile 'D:\path\to\project\.env' `
  -TargetDatabase 'project_name' `
  -TargetUser 'project_name' `
  -TargetEnvFile 'D:\path\to\project\.env'
```

The migration creates a separate database and login role, restores a custom
format dump, and replaces `DATABASE_URL` in the target env file with this
host's Tailscale MagicDNS name. It refuses to overwrite an existing target
database.

On another application machine, run `install-windows.ps1`, sign in to the same
tailnet, and pull or otherwise transfer the project's env file. Tailscale
provides the private network path but does not distribute PostgreSQL passwords.
