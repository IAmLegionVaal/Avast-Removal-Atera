# Avast Complete Removal for Atera

`Avast-Complete-Removal-Atera.ps1` is a single-run Windows PowerShell script for Atera.

It targets:

- Avast Free Antivirus
- Avast One
- Avast Premium Security and other Avast antivirus variants
- Avast Secure Browser
- Avast Update Helper
- Other Avast-branded applications that expose a registered Windows uninstaller

## How it works

- Runs unattended as **System** or an administrator.
- Detects Avast products from both 32-bit and 64-bit uninstall registry views.
- Detects loaded-user uninstall entries.
- Uses Avast's installed `Instup.exe` engine with:

```text
/control_panel /instop:uninstall /silent /wait
```

- Adds `SilentUninstallEnabled=1` to the nearby `Stats.ini` file.
- Uses registered quiet uninstall commands for separate Avast applications.
- Uses Chromium uninstall switches for Avast Secure Browser.
- Verifies that Avast uninstall entries are gone before deleting residual folders.
- Does not report success while Avast is still registered.

## Atera deployment

1. Download `Avast-Complete-Removal-Atera.ps1` directly from this repository.
2. Upload the `.ps1` file to Atera.
3. Configure it to run as **System**.
4. Run it with no parameters.

Optional automatic restart:

```powershell
-Restart
```

## Logs and status

Logs:

```text
C:\ProgramData\AteraScriptLogs\AvastRemoval-*.log
```

Latest status:

```text
C:\ProgramData\AteraScriptLogs\AvastRemoval-LastStatus.txt
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Avast removed successfully, or Avast was not detected |
| 1 | Avast remains registered after the uninstall attempts |
| 5 | Avast remains and Self-Defense was detected |
| 10 | Administrator/System rights were not available |
| 20 | Unexpected script error |
| 3010 | Avast is unregistered, but Windows must restart to unload remaining components |

## Important notes

- The script never edits Avast's Self-Defense registry value. It detects the setting and reports when it may be blocking removal.
- Avast One may still require Avast Clear in Safe Mode when its normal installed uninstaller refuses unattended removal.
- Test on a small device group before wider deployment.
