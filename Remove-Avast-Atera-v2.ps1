#requires -version 5.1
<#
.SYNOPSIS
    Silently removes Avast consumer antivirus products when deployed through Atera.

.DESCRIPTION
    - Designed for unattended execution as LocalSystem or an administrator.
    - Applies a process-scoped ExecutionPolicy bypass after the script starts.
    - Uses Avast's installed uninstaller: instup.exe /instop:uninstall /silent.
    - Enables Avast's documented SilentUninstallEnabled setting in Stats.ini.
    - Does not display menus or prompts.
    - Does not automatically restart unless -Restart is supplied.
    - Safe to run repeatedly; returns success when Avast Antivirus is already absent.

.PARAMETER Restart
    Restarts Windows after a successful uninstall. Omit this switch for normal Atera use.

.EXIT CODES
    0  = Avast is absent, or uninstall was successfully started/completed.
    1  = Avast still appears installed after all uninstall methods were attempted.
    10 = Script was not run with administrative rights.
    20 = Unexpected script failure.
#>

[CmdletBinding()]
param(
    [switch]$Restart
)

# Best-effort execution-policy preparation for unattended RMM execution.
# This changes only the current PowerShell process and does not weaken the
# machine-wide policy. It cannot and should not bypass AppLocker, WDAC, or a
# Group Policy rule that prevents the script from starting.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
}
catch {
    # The script is already running, so continue if an enforced policy prevents
    # changing the process-scoped value.
}

# Remove Mark-of-the-Web from the local script copy when possible. This is a
# best-effort step for subsequent runs; Atera-created script files normally do
# not carry this mark.
try {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
    }
}
catch {
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Atera can launch a 32-bit PowerShell host. Relaunch in native 64-bit PowerShell
# so 64-bit registry and Program Files paths are handled correctly.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $NativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'

    if (Test-Path -LiteralPath $NativePowerShell) {
        $RelaunchArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Restart) {
            $RelaunchArguments += ' -Restart'
        }

        $NativeProcess = Start-Process -FilePath $NativePowerShell `
            -ArgumentList $RelaunchArguments `
            -WindowStyle Hidden `
            -Wait `
            -PassThru

        exit $NativeProcess.ExitCode
    }
}

$LogDirectory = Join-Path $env:ProgramData 'AteraScriptLogs'
$LogFile = Join-Path $LogDirectory ("Remove-Avast-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $Line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Output $Line

    try {
        Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Console output remains available to Atera even if file logging fails.
    }
}

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AvastAntivirusEntries {
    $RegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $Results = foreach ($RegistryPath in $RegistryPaths) {
        Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and
                $_.DisplayName -match '(?i)^Avast.*(Free Antivirus|Antivirus|Premium Security|Internet Security|Pro Antivirus|Premier|One(?: Essential)?)' -and
                $_.DisplayName -notmatch '(?i)Secure Browser|Cleanup|Driver Updater|AntiTrack|VPN|Password'
            } |
            Select-Object DisplayName, DisplayVersion, InstallLocation,
                UninstallString, QuietUninstallString, PSPath, PSChildName
    }

    return @($Results | Sort-Object PSPath -Unique)
}

function Get-AvastSetupExecutables {
    param(
        [object[]]$InstalledEntries
    )

    $Candidates = [System.Collections.Generic.List[string]]::new()
    $ProgramRoots = @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($Root in $ProgramRoots) {
        $KnownPath = Join-Path $Root 'Avast Software\Avast\setup\instup.exe'
        if (Test-Path -LiteralPath $KnownPath) {
            [void]$Candidates.Add($KnownPath)
        }

        $VendorRoot = Join-Path $Root 'Avast Software'
        if (Test-Path -LiteralPath $VendorRoot) {
            Get-ChildItem -LiteralPath $VendorRoot -Filter 'instup.exe' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { [void]$Candidates.Add($_.FullName) }
        }
    }

    foreach ($Entry in $InstalledEntries) {
        if ($Entry.InstallLocation) {
            $InstallLocation = [Environment]::ExpandEnvironmentVariables([string]$Entry.InstallLocation).Trim('"')
            $InstallCandidates = @(
                (Join-Path $InstallLocation 'setup\instup.exe'),
                (Join-Path $InstallLocation 'instup.exe')
            )

            foreach ($InstallCandidate in $InstallCandidates) {
                if (Test-Path -LiteralPath $InstallCandidate) {
                    [void]$Candidates.Add($InstallCandidate)
                }
            }
        }

        foreach ($UninstallValue in @($Entry.QuietUninstallString, $Entry.UninstallString)) {
            if ($UninstallValue -and $UninstallValue -match '(?i)([A-Z]:\\[^\"]*?instup\.exe)') {
                $Executable = $Matches[1]
                if (Test-Path -LiteralPath $Executable) {
                    [void]$Candidates.Add($Executable)
                }
            }
            elseif ($UninstallValue -and $UninstallValue -match '(?i)\"([^\"]*?instup\.exe)\"') {
                $Executable = $Matches[1]
                if (Test-Path -LiteralPath $Executable) {
                    [void]$Candidates.Add($Executable)
                }
            }
        }
    }

    return @($Candidates | Sort-Object -Unique)
}

function Enable-AvastSilentUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SetupExecutable
    )

    $StatsFile = Join-Path (Split-Path -Path $SetupExecutable -Parent) 'Stats.ini'

    if (-not (Test-Path -LiteralPath $StatsFile)) {
        Write-Log "Stats.ini was not found beside $SetupExecutable. Continuing with the silent uninstall command." 'WARN'
        return
    }

    $Lines = [System.Collections.Generic.List[string]]::new()
    [System.IO.File]::ReadAllLines($StatsFile) | ForEach-Object { [void]$Lines.Add($_) }

    $CommonSectionIndex = -1
    $NextSectionIndex = $Lines.Count
    $KeyIndex = -1

    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        if ($Lines[$Index] -match '^\s*\[Common\]\s*$') {
            $CommonSectionIndex = $Index
            continue
        }

        if ($CommonSectionIndex -ge 0 -and $Index -gt $CommonSectionIndex) {
            if ($Lines[$Index] -match '^\s*\[') {
                $NextSectionIndex = $Index
                break
            }

            if ($Lines[$Index] -match '^\s*SilentUninstallEnabled\s*=') {
                $KeyIndex = $Index
                break
            }
        }
    }

    if ($KeyIndex -ge 0) {
        $Lines[$KeyIndex] = 'SilentUninstallEnabled=1'
    }
    elseif ($CommonSectionIndex -ge 0) {
        $Lines.Insert($NextSectionIndex, 'SilentUninstallEnabled=1')
    }
    else {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') {
            [void]$Lines.Add('')
        }
        [void]$Lines.Add('[Common]')
        [void]$Lines.Add('SilentUninstallEnabled=1')
    }

    [System.IO.File]::WriteAllLines($StatsFile, $Lines.ToArray(), [System.Text.Encoding]::ASCII)
    Write-Log 'Enabled Avast silent uninstall mode.'
}

function Stop-AvastUserProcesses {
    $ProcessNames = @(
        'AvastUI',
        'AvastBrowser',
        'AvastBrowserCrashHandler',
        'AvastBrowserCrashHandler64',
        'instup'
    )

    foreach ($ProcessName in $ProcessNames) {
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}


function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string]$Arguments,

        [string]$WorkingDirectory,

        [int]$TimeoutSeconds = 900
    )

    $StartParameters = @{
        FilePath    = $FilePath
        WindowStyle = 'Hidden'
        PassThru    = $true
    }

    if ($Arguments) {
        $StartParameters.ArgumentList = $Arguments
    }

    if ($WorkingDirectory) {
        $StartParameters.WorkingDirectory = $WorkingDirectory
    }

    $Process = Start-Process @StartParameters
    $Exited = $Process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $Exited) {
        try {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
        }

        throw "Process timed out after $TimeoutSeconds seconds: $FilePath"
    }

    $Process.Refresh()
    return $Process.ExitCode
}

function Invoke-AvastInstalledUninstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SetupExecutable
    )

    Write-Log "Starting Avast silent uninstall from: $SetupExecutable"

    try {
        Enable-AvastSilentUninstall -SetupExecutable $SetupExecutable
    }
    catch {
        Write-Log "Could not update Stats.ini: $($_.Exception.Message). The uninstall command will still be attempted." 'WARN'
    }

    Stop-AvastUserProcesses

    $ExitCode = Invoke-ProcessWithTimeout `
        -FilePath $SetupExecutable `
        -Arguments '/instop:uninstall /silent' `
        -WorkingDirectory (Split-Path -Path $SetupExecutable -Parent) `
        -TimeoutSeconds 900

    Write-Log "Avast uninstaller returned exit code $ExitCode."
    return $ExitCode
}

function Split-CommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $ExpandedCommandLine = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())

    if ($ExpandedCommandLine -match '^\s*\"([^\"]+)\"\s*(.*)$') {
        return [pscustomobject]@{
            FilePath  = $Matches[1]
            Arguments = $Matches[2]
        }
    }

    if ($ExpandedCommandLine -match '^\s*([^\s]+\.exe)\s*(.*)$') {
        return [pscustomobject]@{
            FilePath  = $Matches[1]
            Arguments = $Matches[2]
        }
    }

    return $null
}

function Invoke-RegistryUninstallFallback {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $CommandLine = $null

    if ($Entry.QuietUninstallString) {
        $CommandLine = [string]$Entry.QuietUninstallString
    }
    elseif ($Entry.UninstallString -and $Entry.UninstallString -match '(?i)msiexec(?:\.exe)?') {
        $ProductCode = $null
        if ($Entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            $ProductCode = $Entry.PSChildName
        }
        elseif ($Entry.UninstallString -match '(\{[0-9A-Fa-f-]+\})') {
            $ProductCode = $Matches[1]
        }

        if ($ProductCode) {
            $CommandLine = "msiexec.exe /x $ProductCode /qn /norestart"
        }
    }

    if (-not $CommandLine) {
        return $false
    }

    $ParsedCommand = Split-CommandLine -CommandLine $CommandLine
    if (-not $ParsedCommand) {
        Write-Log "Could not parse the registered uninstall command for $($Entry.DisplayName)." 'WARN'
        return $false
    }

    Write-Log "Running the registered silent uninstaller for $($Entry.DisplayName)."

    $ExitCode = Invoke-ProcessWithTimeout `
        -FilePath $ParsedCommand.FilePath `
        -Arguments $ParsedCommand.Arguments `
        -TimeoutSeconds 900

    Write-Log "Registered uninstaller returned exit code $ExitCode."
    return ($ExitCode -in 0, 1605, 1614, 1641, 3010)
}

function Wait-ForAvastUninstall {
    param(
        [int]$TimeoutSeconds = 300
    )

    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()

    do {
        if ((Get-AvastAntivirusEntries).Count -eq 0) {
            return $true
        }

        Start-Sleep -Seconds 5
    }
    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    return ((Get-AvastAntivirusEntries).Count -eq 0)
}

function Remove-AvastLeftoverFolders {
    $Folders = [System.Collections.Generic.List[string]]::new()
    $ProgramRoots = @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($Root in $ProgramRoots) {
        [void]$Folders.Add((Join-Path $Root 'Avast Software\Avast'))
    }

    [void]$Folders.Add((Join-Path $env:ProgramData 'Avast Software\Avast'))

    foreach ($Folder in ($Folders | Sort-Object -Unique)) {
        if (Test-Path -LiteralPath $Folder) {
            try {
                Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed leftover folder: $Folder"
            }
            catch {
                Write-Log "A locked leftover folder remains until Windows restarts: $Folder" 'WARN'
            }
        }
    }
}

try {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

    if (-not (Test-IsAdministrator)) {
        Write-Log 'Administrative rights are required. Configure the Atera script to run as System.' 'ERROR'
        exit 10
    }

    Write-Log "Starting Avast Antivirus removal on $env:COMPUTERNAME as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."

    $InstalledEntries = Get-AvastAntivirusEntries

    if ($InstalledEntries.Count -eq 0) {
        Write-Log 'Avast Antivirus is not installed. No action is required.' 'SUCCESS'
        exit 0
    }

    foreach ($Entry in $InstalledEntries) {
        Write-Log "Found $($Entry.DisplayName) $($Entry.DisplayVersion)."
    }

    $SetupExecutables = Get-AvastSetupExecutables -InstalledEntries $InstalledEntries
    $UninstallAttempted = $false

    foreach ($SetupExecutable in $SetupExecutables) {
        try {
            $UninstallAttempted = $true
            [void](Invoke-AvastInstalledUninstaller -SetupExecutable $SetupExecutable)

            if (Wait-ForAvastUninstall -TimeoutSeconds 300) {
                break
            }
        }
        catch {
            Write-Log "The Avast installed uninstaller failed: $($_.Exception.Message)" 'WARN'
        }
    }

    $RemainingEntries = Get-AvastAntivirusEntries

    if ($RemainingEntries.Count -gt 0) {
        foreach ($Entry in $RemainingEntries) {
            try {
                if (Invoke-RegistryUninstallFallback -Entry $Entry) {
                    $UninstallAttempted = $true
                }
            }
            catch {
                Write-Log "The registered uninstall fallback failed for $($Entry.DisplayName): $($_.Exception.Message)" 'WARN'
            }
        }

        if ($UninstallAttempted) {
            [void](Wait-ForAvastUninstall -TimeoutSeconds 180)
        }
    }

    $RemainingEntries = Get-AvastAntivirusEntries

    if ($RemainingEntries.Count -gt 0) {
        $RemainingNames = ($RemainingEntries.DisplayName | Sort-Object -Unique) -join ', '
        Write-Log "Removal was attempted, but Windows still reports the following product(s) as installed: $RemainingNames" 'ERROR'
        Write-Log "Log file: $LogFile" 'INFO'
        exit 1
    }

    Stop-AvastUserProcesses
    Remove-AvastLeftoverFolders

    Write-Log 'Avast Antivirus removal completed successfully. A Windows restart is recommended to unload any remaining filter drivers.' 'SUCCESS'
    Write-Log "Log file: $LogFile"

    if ($Restart) {
        Write-Log 'Restarting Windows now because the -Restart switch was supplied.'
        Restart-Computer -Force
    }

    exit 0
}
catch {
    try {
        Write-Log "Unexpected failure: $($_.Exception.Message)" 'ERROR'
        Write-Log "Log file: $LogFile"
    }
    catch {
        Write-Output "Unexpected failure: $($_.Exception.Message)"
    }

    exit 20
}
