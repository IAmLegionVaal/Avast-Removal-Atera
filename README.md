# Avast Complete Removal for Atera

`Avast-Complete-Removal-Atera.ps1` is a single-run Windows PowerShell script intended for authorized removal of Avast products through Atera.

It targets:

- Avast Free Antivirus
- Avast One
- Avast Premium Security and other Avast antivirus variants
- Avast Secure Browser
- Avast Update Helper
- Other Avast-branded applications that expose a registered Windows uninstaller

## How it works

- Runs unattended as **Local System** or an administrator.
- Detects Avast products from both 32-bit and 64-bit machine uninstall registry views.
- Uses Avast's installed `Instup.exe` engine with its silent control-panel uninstall arguments.
- Enables Avast's documented `SilentUninstallEnabled=1` setting in the nearby `Stats.ini` file when available.
- Uses registered quiet uninstall commands for separate Avast applications.
- Uses silent browser-removal switches for Avast Secure Browser.
- Treats native process exit codes as failures unless they are explicitly allowed.
- Accepts standard successful/restart-required codes for normal uninstallers and the documented not-installed/already-removed MSI codes for MSI packages.
- Verifies that Avast uninstall entries and AppX registrations are gone before deleting residual folders.
- Does not report successful removal while Avast remains registered.

## Atera deployment

1. Download `Avast-Complete-Removal-Atera.ps1` from this repository.
2. Upload the `.ps1` file to Atera.
3. Configure it to run as **System**.
4. Run it with no parameters.

Optional automatic restart:

```powershell
.\Avast-Complete-Removal-Atera.ps1 -Restart
```

Without `-Restart`, exit code `3010` reports that removal succeeded but Windows must restart.

## Logs and status

Logs:

```text
C:\ProgramData\AteraScriptLogs\AvastRemoval-*.log
```

Latest status:

```text
C:\ProgramData\AteraScriptLogs\AvastRemoval-LastStatus.txt
```

Each native uninstaller exit code is recorded. Unexpected nonzero codes are logged as failed uninstall attempts rather than being treated as success.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Avast removed successfully, or Avast was not detected |
| 1 | Avast remains registered after the uninstall attempts |
| 5 | Avast remains and Self-Defense was detected |
| 10 | Administrator/System rights were not available |
| 20 | Unexpected script error |
| 3010 | Avast is unregistered, but Windows must restart to unload remaining components |

## Validation

Every pull request and push to `main` runs:

- PowerShell parser validation for all `.ps1` files
- PSScriptAnalyzer with error-severity findings treated as CI failures

Runtime behavior must still be piloted on a small representative endpoint group before broad deployment.

## Important notes

- The script does not edit Avast's Self-Defense registry value. It detects the setting and reports when it may be blocking removal.
- Avast One may still require Avast Clear in Safe Mode when its installed uninstaller refuses authorized unattended removal.
- Test on a small device group before wider deployment.
- Use this only on systems where you are authorized to remove the installed security product.
