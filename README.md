# Avast Removal Script for Atera

`Remove-Avast-Atera-v2.ps1` silently removes supported Avast consumer antivirus products from Windows laptops when deployed through Atera.

## How it works

- Runs unattended with no menus or user prompts.
- Designed to run as **System** or an administrator.
- Applies a process-level PowerShell execution-policy bypass.
- Relaunches in 64-bit PowerShell when required.
- Uses Avast's installed silent uninstaller.
- Falls back to the registered Windows uninstall command if needed.
- Removes remaining Avast Antivirus folders after a successful uninstall.
- Does not automatically restart the laptop unless `-Restart` is supplied.

## Atera deployment

1. Upload `Remove-Avast-Atera-v2.ps1` to Atera.
2. Set the script to run as **System**.
3. Run it with no parameters for silent removal without a restart.

Optional restart:

```powershell
-Restart
```

## Logs

Logs are written to:

```text
C:\ProgramData\AteraScriptLogs
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Avast removed successfully or was not installed |
| 1 | Avast still appears installed after removal attempts |
| 10 | Administrator/System rights were not available |
| 20 | Unexpected script error |

## Notes

- A restart is recommended after removal so any remaining Avast drivers can unload.
- The script targets Avast antivirus products and does not intentionally remove Avast Secure Browser, Cleanup, VPN, Driver Updater, AntiTrack, or Password products.
- The built-in bypass handles normal PowerShell execution-policy restrictions. It cannot override AppLocker, WDAC, or a policy that prevents PowerShell from starting.
