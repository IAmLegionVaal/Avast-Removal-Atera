[CmdletBinding()]
param(
    [switch]$Restart,
    [ValidateRange(300,3600)][int]$TimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Version = '7.1.0'
$LogDir = Join-Path $env:ProgramData 'AteraScriptLogs'
$LogFile = Join-Path $LogDir ('AvastRemoval-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$StatusFile = Join-Path $LogDir 'AvastRemoval-LastStatus.txt'
$script:RestartNeeded = $false
$script:SelfDefense = $false

function Log {
    param([string]$Text,[ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level='INFO')
    $Line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date),$Level,$Text
    Write-Output $Line
    try { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 } catch {}
}

function Status([string]$Text) {
    try { Set-Content -LiteralPath $StatusFile -Value $Text -Encoding UTF8 -Force } catch {}
}

function Is-Admin {
    try {
        $I = [Security.Principal.WindowsIdentity]::GetCurrent()
        $P = New-Object Security.Principal.WindowsPrincipal($I)
        return $P.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Is-AvastText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)(^|\W)avast(\W|$)|avast software|avast browser')
}

function Get-AvastEntries {
    $Out = New-Object System.Collections.Generic.List[object]
    foreach ($View in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
        $Base = $null; $Root = $null
        try {
            $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$View)
            $Root = $Base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $Root) { continue }
            foreach ($Name in $Root.GetSubKeyNames()) {
                $K = $null
                try {
                    $K = $Root.OpenSubKey($Name)
                    if ($null -eq $K) { continue }
                    $D = [string]$K.GetValue('DisplayName')
                    $P = [string]$K.GetValue('Publisher')
                    $L = [string]$K.GetValue('InstallLocation')
                    $U = [string]$K.GetValue('UninstallString')
                    $Q = [string]$K.GetValue('QuietUninstallString')
                    if (Is-AvastText (@($D,$P,$L,$U,$Q) -join ' ')) {
                        $Out.Add([pscustomobject]@{
                            Scope='Machine'; KeyName=$Name; DisplayName=$D
                            DisplayVersion=[string]$K.GetValue('DisplayVersion')
                            InstallLocation=$L; UninstallString=$U; QuietUninstallString=$Q
                            WindowsInstaller=$K.GetValue('WindowsInstaller')
                            RegistryPath=('HKLM\Uninstall\' + $Name + '\' + [string]$View)
                        })
                    }
                } catch {} finally { if ($null -ne $K) { $K.Dispose() } }
            }
        } catch {} finally {
            if ($null -ne $Root) { $Root.Dispose() }
            if ($null -ne $Base) { $Base.Dispose() }
        }
    }

    try {
        $Users = [Microsoft.Win32.Registry]::Users
        foreach ($Sid in $Users.GetSubKeyNames()) {
            if ($Sid -notmatch '^S-1-5-21-' -or $Sid -match '_Classes$') { continue }
            $Root = $null
            try {
                $Root = $Users.OpenSubKey($Sid + '\Software\Microsoft\Windows\CurrentVersion\Uninstall')
                if ($null -eq $Root) { continue }
                foreach ($Name in $Root.GetSubKeyNames()) {
                    $K = $null
                    try {
                        $K = $Root.OpenSubKey($Name)
                        if ($null -eq $K) { continue }
                        $D = [string]$K.GetValue('DisplayName')
                        $P = [string]$K.GetValue('Publisher')
                        $L = [string]$K.GetValue('InstallLocation')
                        $U = [string]$K.GetValue('UninstallString')
                        $Q = [string]$K.GetValue('QuietUninstallString')
                        if (Is-AvastText (@($D,$P,$L,$U,$Q) -join ' ')) {
                            $Out.Add([pscustomobject]@{
                                Scope='User'; KeyName=$Name; DisplayName=$D
                                DisplayVersion=[string]$K.GetValue('DisplayVersion')
                                InstallLocation=$L; UninstallString=$U; QuietUninstallString=$Q
                                WindowsInstaller=$K.GetValue('WindowsInstaller')
                                RegistryPath=('HKU\' + $Sid + '\Uninstall\' + $Name)
                            })
                        }
                    } catch {} finally { if ($null -ne $K) { $K.Dispose() } }
                }
            } catch {} finally { if ($null -ne $Root) { $Root.Dispose() } }
        }
    } catch {}
    return @($Out | Sort-Object RegistryPath -Unique)
}

function Split-Command([string]$CommandLine) {
    $S = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($S -match '^\s*"([^"]+)"\s*(.*)$') { return [pscustomobject]@{File=$Matches[1];Args=$Matches[2]} }
    if ($S -match '^\s*(.+?\.exe)\s*(.*)$') { return [pscustomobject]@{File=$Matches[1].Trim();Args=$Matches[2]} }
    return $null
}

function Run-Process {
    param([string]$File,[string]$Args='',[string]$WorkingDirectory='',[int]$Timeout=$TimeoutSeconds)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw ('Executable not found: ' + $File) }
    Log ('Executing: "{0}" {1}' -f $File,$Args)
    $SI = New-Object System.Diagnostics.ProcessStartInfo
    $SI.FileName=$File; $SI.Arguments=$Args; $SI.UseShellExecute=$false; $SI.CreateNoWindow=$true
    $SI.WindowStyle=[System.Diagnostics.ProcessWindowStyle]::Hidden
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { $SI.WorkingDirectory=$WorkingDirectory }
    $P = New-Object System.Diagnostics.Process; $P.StartInfo=$SI
    try {
        if (-not $P.Start()) { throw ('Could not start: ' + $File) }
        if (-not $P.WaitForExit($Timeout*1000)) { try {$P.Kill()} catch {}; throw ('Timed out: ' + $File) }
        $Code=$P.ExitCode; Log ('Process exit code: {0}' -f $Code)
        if ($Code -in 1641,3010) { $script:RestartNeeded=$true }
        return $Code
    } finally { $P.Dispose() }
}

function Self-Defense-On {
    $Targets=@(
        @{Path='HKLM:\SOFTWARE\Avast Software\Avast\properties\settings\SelfDefense';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\Avast Software\Avast\properties\settings';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Avast Software\Avast\properties\settings\SelfDefense';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Avast Software\Avast\properties\settings';Name='SelfDefense'}
    )
    foreach ($T in $Targets) {
        try {
            if (-not (Test-Path -LiteralPath $T.Path)) { continue }
            $V=(Get-ItemProperty -LiteralPath $T.Path -Name $T.Name -ErrorAction Stop).($T.Name)
            if ($null -ne $V -and [int]$V -ne 0) { Log ('Self-Defense is enabled at {0}.' -f $T.Path) 'WARN'; return $true }
        } catch {}
    }
    return $false
}

function Enable-Silent([string]$Instup) {
    $Stats=Join-Path ([System.IO.Path]::GetDirectoryName($Instup)) 'Stats.ini'
    if (-not (Test-Path -LiteralPath $Stats -PathType Leaf)) { Log ('Stats.ini not found beside {0}.' -f $Instup) 'WARN'; return }
    try {
        $C=[System.IO.File]::ReadAllText($Stats)
        if ($C -match '(?im)^\s*SilentUninstallEnabled\s*=') {
            $C=[regex]::Replace($C,'(?im)^\s*SilentUninstallEnabled\s*=.*$','SilentUninstallEnabled=1')
        } elseif ($C -match '(?im)^\s*\[Common\]\s*$') {
            $C=[regex]::Replace($C,'(?im)^\s*\[Common\]\s*$',"[Common]`r`nSilentUninstallEnabled=1",1)
        } else { $C=$C.TrimEnd()+"`r`n`r`n[Common]`r`nSilentUninstallEnabled=1`r`n" }
        [System.IO.File]::WriteAllText($Stats,$C,[System.Text.Encoding]::ASCII)
        Log ('Enabled silent uninstall in {0}.' -f $Stats)
    } catch { Log ('Could not update {0}: {1}' -f $Stats,$_.Exception.Message) 'WARN' }
}

function Get-InstupPaths {
    $R=New-Object System.Collections.Generic.List[string]
    foreach ($Root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)}) | Where-Object {$_} | Select-Object -Unique) {
        $A=Join-Path $Root 'Avast Software'
        if (-not (Test-Path -LiteralPath $A -PathType Container)) { continue }
        foreach ($F in @(Get-ChildItem -LiteralPath $A -Filter 'Instup.exe' -File -Recurse -ErrorAction SilentlyContinue)) {
            if (-not $R.Contains($F.FullName)) { [void]$R.Add($F.FullName) }
        }
    }
    foreach ($E in (Get-AvastEntries)) {
        foreach ($C in @($E.QuietUninstallString,$E.UninstallString)) {
            if (-not $C) { continue }; $X=Split-Command $C
            if ($null -ne $X -and [System.IO.Path]::GetFileName($X.File) -ieq 'Instup.exe' -and (Test-Path -LiteralPath $X.File)) {
                if (-not $R.Contains($X.File)) { [void]$R.Add($X.File) }
            }
        }
    }
    return $R.ToArray()
}

function Is-Core([string]$Name) {
    return ($Name -match '(?i)avast\s+(one|free antivirus|antivirus|premium security|internet security|ultimate|premier|pro antivirus)')
}

function Remove-Core {
    $Engines=@(Get-InstupPaths)
    if ($Engines.Count -eq 0) { Log 'No Avast Instup.exe engine found.' 'WARN'; return }
    foreach ($I in $Engines) {
        try {
            Enable-Silent $I
            [void](Run-Process $I '/control_panel /instop:uninstall /silent /wait' ([System.IO.Path]::GetDirectoryName($I)))
            Start-Sleep 10
        } catch { Log ('Core uninstall failed from {0}: {1}' -f $I,$_.Exception.Message) 'WARN' }
    }
}

function Remove-Msi($E) {
    $G=$null
    if ($E.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {$G=$E.KeyName}
    elseif ($E.UninstallString -match '(\{[0-9A-Fa-f-]{36}\})') {$G=$Matches[1]}
    if (-not $G) { return $false }
    try { [void](Run-Process (Join-Path $env:WINDIR 'System32\msiexec.exe') ('/x {0} /qn /norestart' -f $G)); return $true }
    catch { Log ('MSI uninstall failed for {0}: {1}' -f $E.DisplayName,$_.Exception.Message) 'WARN'; return $false }
}

function Remove-Entry($E) {
    Log ('Processing: {0} {1}' -f $E.DisplayName,$E.DisplayVersion)
    if ($E.WindowsInstaller -eq 1 -or $E.UninstallString -match '(?i)\bmsiexec(?:\.exe)?\b') { return (Remove-Msi $E) }
    $C=$E.QuietUninstallString; if (-not $C) {$C=$E.UninstallString}; if (-not $C) {Log ('No uninstall command for {0}.' -f $E.DisplayName) 'WARN'; return $false}
    $X=Split-Command $C; if ($null -eq $X) {Log ('Could not parse uninstall command for {0}.' -f $E.DisplayName) 'WARN'; return $false}
    $F=$X.File; $A=$X.Args; $N=[System.IO.Path]::GetFileName($F)
    if (-not (Test-Path -LiteralPath $F -PathType Leaf)) {Log ('Uninstaller missing for {0}: {1}' -f $E.DisplayName,$F) 'WARN'; return $false}
    if ($N -ieq 'Instup.exe') {Enable-Silent $F; $A='/control_panel /instop:uninstall /silent /wait'}
    elseif ($E.DisplayName -match '(?i)secure browser' -or $F -match '(?i)avast.*browser') {
        if ($A -notmatch '(?i)--uninstall') {$A+=' --uninstall'}
        if ($F -match '(?i)\\users\\' -or $A -match '(?i)--user-level') {if ($A -notmatch '(?i)--user-level') {$A+=' --user-level'}}
        else {if ($A -notmatch '(?i)--system-level') {$A+=' --system-level'}}
        if ($A -notmatch '(?i)--force-uninstall') {$A+=' --force-uninstall'}
        if ($A -notmatch '(?i)--verbose-logging') {$A+=' --verbose-logging'}
    }
    elseif ($N -match '(?i)^unins\d*\.exe$') {$A='/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'}
    elseif (-not $E.QuietUninstallString -and $A -notmatch '(?i)(/s\b|/silent\b|/quiet\b|/qn\b|--silent\b|--force-uninstall\b)') {$A+=' /silent /norestart'}
    try {[void](Run-Process $F $A.Trim() ([System.IO.Path]::GetDirectoryName($F))); return $true}
    catch {Log ('Uninstall failed for {0}: {1}' -f $E.DisplayName,$_.Exception.Message) 'WARN'; return $false}
}

function Get-Procs {
    try {return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '(?i)^(avast|asw|afw|wsc_proxy)' -or $_.ExecutablePath -match '(?i)\\avast software\\|\\avast\\|\\avast browser\\'})} catch {return @()}
}
function Get-Services {
    try {return @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '(?i)^(avast|asw|afw)' -or $_.DisplayName -match '(?i)avast' -or $_.PathName -match '(?i)\\avast software\\|\\avast\\'})} catch {return @()}
}
function Get-Appx {
    try {return @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '(?i)avast' -or $_.PackageFullName -match '(?i)avast' -or $_.Publisher -match '(?i)avast'})} catch {return @()}
}
function Get-Provisioned {
    try {return @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -match '(?i)avast' -or $_.PackageName -match '(?i)avast'})} catch {return @()}
}
function Remove-Appx {
    foreach ($P in (Get-Appx)) {try {Log ('Removing AppX {0}.' -f $P.PackageFullName); Remove-AppxPackage -Package $P.PackageFullName -AllUsers -ErrorAction Stop} catch {try {Remove-AppxPackage -Package $P.PackageFullName -ErrorAction Stop} catch {Log ('AppX removal failed: {0}' -f $_.Exception.Message) 'WARN'}}}
    foreach ($P in (Get-Provisioned)) {try {Remove-AppxProvisionedPackage -Online -PackageName $P.PackageName -AllUsers -ErrorAction Stop | Out-Null} catch {Log ('Provisioned AppX removal failed: {0}' -f $_.Exception.Message) 'WARN'}}
}

function Remove-Tasks {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {return}
    foreach ($T in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {$_.TaskName -match '(?i)avast' -or $_.TaskPath -match '(?i)avast'})) {
        try {Unregister-ScheduledTask -TaskName $T.TaskName -TaskPath $T.TaskPath -Confirm:$false -ErrorAction Stop; Log ('Removed task {0}{1}.' -f $T.TaskPath,$T.TaskName)} catch {}
    }
}

function Folder-List {
    $R=New-Object System.Collections.Generic.List[string]
    foreach ($Root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData) | Where-Object {$_} | Select-Object -Unique) {$P=Join-Path $Root 'Avast Software'; if (-not $R.Contains($P)) {[void]$R.Add($P)}}
    $UR=Join-Path $env:SystemDrive 'Users'
    if (Test-Path $UR) {foreach ($U in @(Get-ChildItem $UR -Directory -Force -ErrorAction SilentlyContinue | Where-Object {$_.Name -notin @('All Users','Default','Default User','Public')})) {foreach ($Rel in @('AppData\Local\Avast Software','AppData\Roaming\Avast Software')) {$P=Join-Path $U.FullName $Rel; if (-not $R.Contains($P)) {[void]$R.Add($P)}}}}
    return $R.ToArray()
}

function Clean-Folders {
    foreach ($P in (Get-Procs)) {try {Stop-Process -Id $P.ProcessId -Force -ErrorAction SilentlyContinue} catch {}}
    Start-Sleep 3
    foreach ($F in (Folder-List)) {if (Test-Path $F) {try {Remove-Item $F -Recurse -Force -ErrorAction Stop; Log ('Removed folder {0}.' -f $F)} catch {$script:RestartNeeded=$true; Log ('Folder locked until restart: {0}' -f $F) 'WARN'}}}
}

function State {return [pscustomobject]@{Entries=@(Get-AvastEntries);Appx=@(Get-Appx);Provisioned=@(Get-Provisioned);Processes=@(Get-Procs);Services=@(Get-Services)}}

try {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null; Status 'STARTED'
    if (-not (Is-Admin)) {Log 'Run this Atera script as System.' 'ERROR'; Status 'FAILED: NOT ADMIN'; exit 10}
    Log ('Avast removal {0} started on {1} as {2}.' -f $Version,$env:COMPUTERNAME,[Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $S=State
    if ($S.Entries.Count -eq 0 -and $S.Appx.Count -eq 0 -and $S.Provisioned.Count -eq 0 -and $S.Processes.Count -eq 0 -and $S.Services.Count -eq 0) {Log 'No Avast detected.' 'SUCCESS'; Status 'SUCCESS: NOT DETECTED'; exit 0}
    $script:SelfDefense=Self-Defense-On
    if ($script:SelfDefense) {Log 'Self-Defense is enabled. Uninstall will be attempted, but Avast may block it.' 'WARN'}

    for ($Pass=1;$Pass -le 2;$Pass++) {
        Log ('Starting pass {0}.' -f $Pass)
        $E=@(Get-AvastEntries)
        foreach ($X in @($E | Where-Object {-not (Is-Core $_.DisplayName)})) {[void](Remove-Entry $X); Start-Sleep 3}
        Remove-Core; Start-Sleep 15
        foreach ($X in @(Get-AvastEntries)) {[void](Remove-Entry $X); Start-Sleep 3}
        Remove-Appx; Start-Sleep 10
        $S=State; if ($S.Entries.Count -eq 0 -and $S.Appx.Count -eq 0 -and $S.Provisioned.Count -eq 0) {break}
    }

    $S=State
    if ($S.Entries.Count -eq 0 -and $S.Appx.Count -eq 0 -and $S.Provisioned.Count -eq 0) {Remove-Tasks; Clean-Folders}
    else {Log 'Skipping folder deletion because Avast is still registered.' 'WARN'}
    Start-Sleep 5; $S=State

    if ($S.Entries.Count -gt 0 -or $S.Appx.Count -gt 0 -or $S.Provisioned.Count -gt 0) {
        foreach ($X in $S.Entries) {Log ('Remaining product: {0} {1}' -f $X.DisplayName,$X.DisplayVersion) 'ERROR'}
        if ($script:SelfDefense) {Log 'Self-Defense may have blocked removal. Disable it or use Avast Clear in Safe Mode.' 'ERROR'; Status 'FAILED: SELF-DEFENSE OR AVAST REMAINS'; exit 5}
        Log ('Removal incomplete. Log: {0}' -f $LogFile) 'ERROR'; Status 'FAILED: AVAST REMAINS'; exit 1
    }

    if ($S.Processes.Count -gt 0 -or $S.Services.Count -gt 0) {$script:RestartNeeded=$true}
    if ($script:RestartNeeded) {
        Log 'Avast is unregistered, but Windows must restart to unload remaining components.' 'WARN'; Status 'SUCCESS: RESTART REQUIRED'
        if ($Restart) {Restart-Computer -Force; exit 0}; exit 3010
    }
    Log 'All detected Avast applications were removed.' 'SUCCESS'; Status 'SUCCESS: REMOVED'; exit 0
}
catch {
    try {Log ('Unexpected failure: {0}' -f $_.Exception.Message) 'ERROR'} catch {}
    Status ('FAILED: ' + $_.Exception.Message); exit 20
}
