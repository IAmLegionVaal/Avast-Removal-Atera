# Changelog

## 8.0.0

- Rebuilt the Atera script around Avast's documented command-line removal method.
- Uses `SilentUninstallEnabled=1` in `Stats.ini` and runs only `instup.exe /instop:uninstall /silent`.
- Verifies the installed uninstaller's Authenticode signature before execution.
- Removes unrelated Secure Browser, AppX and residual-deletion logic from the antivirus workflow.
- Verifies uninstall registry entries, Avast Antivirus services and Avast processes after execution.
- Records protection status and returns an explicit restart-required code when appropriate.
- Reports Avast Clear/manual Safe Mode remediation instead of inventing unsupported unattended Avast Clear arguments.
