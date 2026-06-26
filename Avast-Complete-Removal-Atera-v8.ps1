#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Restart,
    [ValidateRange(60,3600)][int]$TimeoutSeconds = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '8.0.0'
$LogDir = Join-Path $env:ProgramData 'AteraScriptLogs'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir "AvastRemoval-$Stamp.log"
$StatusFile = Join-Path $LogDir 'AvastRemoval-LastStatus.txt'
$EvidenceDir = Join-Path $LogDir "AvastRemoval-$Stamp"
$CorePathRegex = '(?i)\\Avast Software\\Avast(?:\\|$)'
$ProductRegex = '(?i)^Avast\s+(Free Antivirus|Premium Security|One(?:\s+\w+)?|Internet Security|Pro Antivirus|Premier|Ultimate|Antivirus)'

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level='INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date),$Level,$Message
    Write-Output $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Set-Status([string]$Value) {
    Set-Content -LiteralPath $StatusFile -Value $Value -Encoding UTF8 -Force
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AvastProducts {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $key = $null
                try {
                    $key = $root.OpenSubKey($name)
                    if ($null -eq $key) { continue }
                    $display = [string]$key.GetValue('DisplayName')
                    $publisher = [string]$key.GetValue('Publisher')
                    $location = [string]$key.GetValue('InstallLocation')
                    $excluded = $display -match '(?i)(Secure Browser|Cleanup|Driver Updater|SecureLine|BreachGuard|AntiTrack|Update Helper)'
                    $isCore = $display -match $ProductRegex -or ($location -match $CorePathRegex -and $publisher -match '(?i)(Avast|Gen Digital)')
                    if ($isCore -and -not $excluded) {
                        $items.Add([pscustomobject]@{
                            RegistryView = [string]$view
                            DisplayName = $display
                            DisplayVersion = [string]$key.GetValue('DisplayVersion')
                            Publisher = $publisher
                            InstallLocation = $location
                            UninstallString = [string]$key.GetValue('UninstallString')
                        })
                    }
                }
                finally { if ($null -ne $key) { $key.Dispose() } }
            }
        }
        finally {
            if ($null -ne $root) { $root.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
    return @($items | Sort-Object -Property @('RegistryView','DisplayName') -Unique)
}

function Get-CoreServices {
    try {
        return @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.PathName -match $CorePathRegex -or $_.DisplayName -match '(?i)^Avast.*Antivirus'
        })
    }
    catch { Write-Log "Service check failed: $($_.Exception.Message)" WARN; return @() }
}

function Get-CoreProcesses {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -match $CorePathRegex
        })
    }
    catch { Write-Log "Process check failed: $($_.Exception.Message)" WARN; return @() }
}

function Find-Instup([object[]]$Products) {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique) {
        [void]$paths.Add((Join-Path $root 'Avast Software\Avast\setup\instup.exe'))
    }
    foreach ($product in $Products) {
        if ($product.InstallLocation) { [void]$paths.Add((Join-Path $product.InstallLocation 'setup\instup.exe')) }
        if ($product.UninstallString -match '(?i)"?([^\"]*\\instup\.exe)"?') {
            [void]$paths.Add([Environment]::ExpandEnvironmentVariables($Matches[1].Trim()))
        }
    }
    return @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

function Test-TrustedInstup([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    Write-Log "Signature: Status=$($signature.Status); Signer=$subject"
    return ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and $subject -match '(?i)(Avast Software|Gen Digital)')
}

function Set-SilentUninstall([string]$InstupPath) {
    $stats = Join-Path (Split-Path $InstupPath -Parent) 'Stats.ini'
    if (-not (Test-Path -LiteralPath $stats -PathType Leaf)) { throw "Stats.ini not found: $stats" }
    $backup = Join-Path $EvidenceDir 'Stats.ini.before'
    Copy-Item -LiteralPath $stats -Destination $backup -Force
    $lines = @(Get-Content -LiteralPath $stats -Encoding Default)
    $common = -1
    for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[Common\]\s*$') { $common=$i; break } }
    if ($common -lt 0) {
        $lines = @($lines + '' + '[Common]' + 'SilentUninstallEnabled=1')
    }
    else {
        $next = $lines.Count
        for ($i=$common+1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[.+\]\s*$') { $next=$i; break } }
        $key = -1
        for ($i=$common+1; $i -lt $next; $i++) { if ($lines[$i] -match '^\s*SilentUninstallEnabled\s*=') { $key=$i; break } }
        if ($key -ge 0) { $lines[$key]='SilentUninstallEnabled=1' }
        else {
            $before=@($lines[0..$common])
            $after=if ($common+1 -lt $lines.Count) { @($lines[($common+1)..($lines.Count-1)]) } else { @() }
            $lines=@($before+'SilentUninstallEnabled=1'+$after)
        }
    }
    Set-Content -LiteralPath $stats -Value $lines -Encoding Default -Force
    if ((Get-Content -LiteralPath $stats -Encoding Default -Raw) -notmatch '(?im)^\s*SilentUninstallEnabled\s*=\s*1\s*$') {
        throw 'SilentUninstallEnabled=1 could not be verified.'
    }
    return [pscustomobject]@{ StatsPath=$stats; BackupPath=$backup }
}

function Restore-Stats($Record) {
    if ($Record -and (Test-Path $Record.BackupPath) -and (Test-Path $Record.StatsPath)) {
        Copy-Item $Record.BackupPath $Record.StatsPath -Force
        Write-Log 'Stats.ini restored because Avast remains installed.' WARN
    }
}

function Wait-Setup([int]$Seconds) {
    $end=(Get-Date).AddSeconds($Seconds)
    do {
        $running=@(Get-CimInstance Win32_Process -Filter "Name='instup.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -match $CorePathRegex })
        if ($running.Count -eq 0) { return $true }
        Start-Sleep 10
    } while ((Get-Date) -lt $end)
    return $false
}

function Invoke-OfficialUninstall([string]$InstupPath) {
    Write-Log 'Running: instup.exe /instop:uninstall /silent'
    $process=Start-Process -FilePath $InstupPath -ArgumentList '/instop:uninstall /silent' -WorkingDirectory (Split-Path $InstupPath -Parent) -PassThru -ErrorAction Stop
    try {
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "Uninstall timed out after $TimeoutSeconds seconds."
        }
        $process.Refresh()
        Write-Log "instup.exe exit code: $($process.ExitCode)"
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

function Save-ProtectionStatus {
    $result=[ordered]@{CheckedAt=Get-Date;SecurityCenterProducts=@();Defender=$null}
    try {
        $result.SecurityCenterProducts=@(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object -Property @('displayName','productState'))
    }
    catch { Write-Log "Security Center status unavailable: $($_.Exception.Message)" WARN }
    try {
        if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
            $mp=Get-MpComputerStatus -ErrorAction Stop
            $result.Defender=[ordered]@{AntivirusEnabled=$mp.AntivirusEnabled;RealTimeProtectionEnabled=$mp.RealTimeProtectionEnabled;AMServiceEnabled=$mp.AMServiceEnabled}
        }
    }
    catch { Write-Log "Defender status unavailable: $($_.Exception.Message)" WARN }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceDir 'ProtectionStatus.json') -Encoding UTF8
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
    New-Item $LogDir -ItemType Directory -Force | Out-Null
    New-Item $EvidenceDir -ItemType Directory -Force | Out-Null
    Set-Status 'STARTED'
    if (-not (Test-Admin)) {
        Write-Log 'Administrator or LocalSystem rights are required. Configure Atera to run this script as System.' ERROR
        Set-Status 'FAILED: NOT ADMIN'; exit 10
    }

    Write-Log "Avast removal $Version started on $env:COMPUTERNAME."
    $products=@(Get-AvastProducts)
    $services=@(Get-CoreServices)
    $processes=@(Get-CoreProcesses)
    $products | Export-Csv (Join-Path $EvidenceDir 'DetectedProducts.csv') -NoTypeInformation -Encoding UTF8

    if ($products.Count -eq 0 -and $services.Count -eq 0 -and $processes.Count -eq 0) {
        Write-Log 'Avast Antivirus was not detected.' SUCCESS
        Save-ProtectionStatus
        Set-Status 'SUCCESS: NOT DETECTED'; exit 0
    }

    $candidates=@(Find-Instup $products)
    $instup=$null
    foreach ($candidate in $candidates) { if (Test-TrustedInstup $candidate) { $instup=$candidate; break } }
    if (-not $instup) {
        Write-Log 'A trusted installed Avast uninstaller was not found. Use Avast Clear manually in Safe Mode.' ERROR
        Set-Status 'FAILED: AVAST CLEAR REQUIRED'; exit 5
    }

    $wait=[Math]::Min(300,$TimeoutSeconds)
    if (-not (Wait-Setup $wait)) {
        Write-Log 'An existing Avast setup process did not finish.' ERROR
        Set-Status 'FAILED: AVAST SETUP BUSY'; exit 5
    }

    $stats=$null
    try {
        $stats=Set-SilentUninstall $instup
        $nativeCode=Invoke-OfficialUninstall $instup
        if (-not (Wait-Setup $wait)) { throw 'Avast setup remained active after uninstall.' }
        [pscustomobject]@{InstupPath=$instup;NativeExitCode=$nativeCode;CompletedAt=Get-Date} | ConvertTo-Json | Set-Content (Join-Path $EvidenceDir 'UninstallProcess.json') -Encoding UTF8
    }
    catch {
        Restore-Stats $stats
        Write-Log "Official silent uninstall failed: $($_.Exception.Message)" ERROR
        Write-Log 'Avast Clear in Safe Mode is the supported fallback.' ERROR
        Set-Status 'FAILED: AVAST CLEAR REQUIRED'; exit 5
    }

    Start-Sleep 15
    $remainingProducts=@(Get-AvastProducts)
    $remainingServices=@(Get-CoreServices)
    $remainingProcesses=@(Get-CoreProcesses)
    $remainingProducts | Export-Csv (Join-Path $EvidenceDir 'RemainingProducts.csv') -NoTypeInformation -Encoding UTF8

    if ($remainingProducts.Count -gt 0) {
        Restore-Stats $stats
        foreach ($item in $remainingProducts) { Write-Log "Avast remains registered: $($item.DisplayName) $($item.DisplayVersion)" ERROR }
        Write-Log 'Disable Self-Defense in Avast or use Avast Clear in Safe Mode.' ERROR
        Set-Status 'FAILED: AVAST REMAINS'; exit 1
    }

    Save-ProtectionStatus
    if ($remainingServices.Count -gt 0 -or $remainingProcesses.Count -gt 0) {
        Write-Log 'Avast is unregistered, but a restart is required to unload remaining components.' WARN
        Set-Status 'SUCCESS: RESTART REQUIRED'
        if ($Restart) { Restart-Computer -Force; exit 0 }
        exit 3010
    }

    Write-Log 'Avast Antivirus was removed successfully.' SUCCESS
    Set-Status 'SUCCESS: REMOVED'; exit 0
}
catch {
    try { Write-Log "Unexpected failure: $($_.Exception.Message)" ERROR } catch {}
    try { Set-Status "FAILED: $($_.Exception.Message)" } catch {}
    exit 20
}
