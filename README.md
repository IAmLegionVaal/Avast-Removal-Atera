# Avast Antivirus Removal for Atera

`Avast-Complete-Removal-Atera-v8.ps1` is a single-run Windows PowerShell script for removing supported Avast Antivirus products through Atera.

## Scope

The script targets the core Avast Antivirus installation, including common variants such as:

- Avast Free Antivirus
- Avast Premium Security
- Avast One
- Avast Internet Security, Pro Antivirus, Premier and Ultimate

It deliberately does **not** combine Secure Browser, Cleanup, Driver Updater, SecureLine, AppX packages or unrelated Avast utilities into the antivirus-removal operation.

## Method

The script follows Avast's published command-line procedure:

1. Locate the installed `Avast Software\Avast\setup\instup.exe`.
2. Verify that the executable has a valid Avast Software or Gen Digital Authenticode signature.
3. Back up `Stats.ini` to the run evidence directory.
4. Set `SilentUninstallEnabled=1` inside the `[Common]` section.
5. Run exactly:

```text
instup.exe /instop:uninstall /silent
```

6. Wait for the uninstall and remaining Avast setup processes.
7. Verify removal using the machine uninstall registry, Avast Antivirus services and processes.
8. Record Windows Security Center and Microsoft Defender status when available.

The script records the native `instup.exe` exit code, but does not treat that code alone as proof of success because Avast does not publish a complete exit-code contract for this command.

## Atera deployment

1. Download `Avast-Complete-Removal-Atera-v8.ps1`.
2. Upload the single `.ps1` file to Atera.
3. Configure the script to run as **System**.
4. Run it with no parameters.

The script does not automatically restart the endpoint. To restart automatically only after Avast is unregistered and loaded components remain:

```powershell
-Restart
```

## Logs and evidence

```text
C:\ProgramData\AteraScriptLogs\AvastRemoval-*.log
C:\ProgramData\AteraScriptLogs\AvastRemoval-LastStatus.txt
C:\ProgramData\AteraScriptLogs\AvastRemoval-<timestamp>\
```

The evidence directory can contain detected products, the original `Stats.ini`, the native process result, remaining products and protection status.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Avast Antivirus removed successfully, or not detected |
| `1` | Avast remains registered after the supported silent command |
| `5` | Supported silent removal could not run; Avast Clear/manual remediation required |
| `10` | Administrator or LocalSystem rights were unavailable |
| `20` | Unexpected script failure |
| `3010` | Avast is unregistered, but Windows must restart to unload remaining components |

## Supported fallback

If the documented silent command does not remove Avast, the script stops and reports failure. It does not disable Self-Defense through undocumented registry edits, invent silent switches for Avast Clear, or delete program folders while Avast remains registered.

Avast's supported fallback is Avast Clear, which uses an interactive Safe Mode workflow. If Self-Defense blocks the command-line method, disable it through the Avast interface before retrying or use Avast Clear.

## Validation status

The script has passed static PowerShell syntax-tree parsing. GitHub Actions performs native PowerShell parser validation and PSScriptAnalyzer checks. Runtime validation on representative Avast installations is still required before broad Atera deployment.

## References

- Avast Removal Tool and command-line removal instructions: `https://www.avast.com/uninstall-utility`
- Microsoft `Start-Process`: `https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process`
- Microsoft `Get-AuthenticodeSignature`: `https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature`
