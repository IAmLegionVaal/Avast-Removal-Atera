#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Restart,
    [ValidateRange(300, 3600)][int]$TimeoutSeconds = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Version = '8.0.0'
$LogDir = Join-Path $env:ProgramData 'AteraScriptLogs'
$LogFile = Join-Path $LogDir ('AvastRemoval-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$StatusFile = Join-Path $LogDir 'AvastRemoval-LastStatus.txt'
$script:RestartNeeded = $false
$script:SelfDefense = $false

function Write-Log {
    param([Parameter(Mandatory)][string]$Message,[ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level='INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date),$Level,$Message
    Write-Output $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { Write-Warning $_.Exception.Message }
}
function Set-Status {
    param([Parameter(Mandatory)][string]$Value)
    try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding UTF8 -Force } catch { Write-Warning $_.Exception.Message }
}
function Test-Admin {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-AvastText {
    param([AllowNull()][string]$Text)
    return (-not [string]::IsNullOrWhiteSpace($Text) -and $Text -match '(?i)(^|\W)avast(\W|$)|avast software|avast browser')
}
function Get-AvastEntries {
    $out=New-Object System.Collections.Generic.List[object]
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)){
        $base=$null;$root=$null
        try{
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $root=$base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if($null -eq $root){continue}
            foreach($name in $root.GetSubKeyNames()){
                $key=$null
                try{
                    $key=$root.OpenSubKey($name);if($null -eq $key){continue}
                    $d=[string]$key.GetValue('DisplayName');$p=[string]$key.GetValue('Publisher')
                    $l=[string]$key.GetValue('InstallLocation');$u=[string]$key.GetValue('UninstallString');$q=[string]$key.GetValue('QuietUninstallString')
                    if(Test-AvastText (@($d,$p,$l,$u,$q)-join ' ')){
                        $out.Add([pscustomobject]@{KeyName=$name;DisplayName=$d;DisplayVersion=[string]$key.GetValue('DisplayVersion');InstallLocation=$l;UninstallString=$u;QuietUninstallString=$q;WindowsInstaller=$key.GetValue('WindowsInstaller');RegistryPath=('HKLM\Uninstall\'+$name+'\'+[string]$view)})
                    }
                }catch{Write-Log "Could not inspect uninstall key '$name': $($_.Exception.Message)" WARN}finally{if($null -ne $key){$key.Dispose()}}
            }
        }finally{if($null -ne $root){$root.Dispose()};if($null -ne $base){$base.Dispose()}}
    }
    return @($out|Sort-Object RegistryPath -Unique)
}
function Split-CommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    $value=[Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if($value -match '^\s*"([^"]+)"\s*(.*)$'){return [pscustomobject]@{File=$Matches[1];Args=$Matches[2]}}
    if($value -match '^\s*(.+?\.exe)\s*(.*)$'){return [pscustomobject]@{File=$Matches[1].Trim();Args=$Matches[2]}}
    return $null
}
function Invoke-ProcessChecked {
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$Args='',
        [string]$WorkingDirectory='',
        [int[]]$SuccessExitCodes=@(0,1641,3010)
    )
    if(-not(Test-Path -LiteralPath $File -PathType Leaf)){throw "Executable not found: $File"}
    Write-Log ('Executing: "{0}" {1}' -f $File,$Args)
    $info=New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName=$File;$info.Arguments=$Args;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    if($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)){$info.WorkingDirectory=$WorkingDirectory}
    $process=New-Object System.Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw "Could not start: $File"}
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){try{$process.Kill();$process.WaitForExit()}catch{};throw "Timed out: $File"}
        $code=$process.ExitCode;Write-Log "Process exit code: $code"
        if($code -in 1641,3010){$script:RestartNeeded=$true}
        if($code -notin $SuccessExitCodes){throw "Unsuccessful exit code $code from $File"}
        return $code
    }finally{$process.Dispose()}
}
function Test-SelfDefense {
    foreach($target in @(
        @{Path='HKLM:\SOFTWARE\Avast Software\Avast\properties\settings\SelfDefense';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\Avast Software\Avast\properties\settings';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Avast Software\Avast\properties\settings\SelfDefense';Name='SelfDefense'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Avast Software\Avast\properties\settings';Name='SelfDefense'}
    )){
        try{if(Test-Path -LiteralPath $target.Path){$value=(Get-ItemProperty -LiteralPath $target.Path -Name $target.Name -ErrorAction Stop).($target.Name);if($null -ne $value -and [int]$value -ne 0){Write-Log "Self-Defense is enabled at $($target.Path)." WARN;return $true}}}catch{}
    }
    return $false
}
function Enable-SilentUninstall {
    param([Parameter(Mandatory)][string]$Instup)
    $stats=Join-Path ([IO.Path]::GetDirectoryName($Instup)) 'Stats.ini'
    if(-not(Test-Path -LiteralPath $stats -PathType Leaf)){Write-Log "Stats.ini not found beside $Instup." WARN;return}
    try{
        $content=[IO.File]::ReadAllText($stats)
        if($content -match '(?im)^\s*SilentUninstallEnabled\s*='){$content=[regex]::Replace($content,'(?im)^\s*SilentUninstallEnabled\s*=.*$','SilentUninstallEnabled=1')}
        elseif($content -match '(?im)^\s*\[Common\]\s*$'){$content=[regex]::Replace($content,'(?im)^\s*\[Common\]\s*$',"[Common]`r`nSilentUninstallEnabled=1",1)}
        else{$content=$content.TrimEnd()+"`r`n`r`n[Common]`r`nSilentUninstallEnabled=1`r`n"}
        [IO.File]::WriteAllText($stats,$content,[Text.Encoding]::ASCII)
    }catch{Write-Log "Could not update $stats`: $($_.Exception.Message)" WARN}
}
function Get-InstupPaths {
    $paths=New-Object System.Collections.Generic.List[string]
    foreach($root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)})|Where-Object{$_}|Select-Object -Unique){
        $avastRoot=Join-Path $root 'Avast Software';if(-not(Test-Path -LiteralPath $avastRoot -PathType Container)){continue}
        foreach($file in @(Get-ChildItem -LiteralPath $avastRoot -Filter Instup.exe -File -Recurse -ErrorAction SilentlyContinue)){if(-not $paths.Contains($file.FullName)){[void]$paths.Add($file.FullName)}}
    }
    foreach($entry in Get-AvastEntries){foreach($command in @($entry.QuietUninstallString,$entry.UninstallString)){if(-not $command){continue};$parsed=Split-CommandLine $command;if($parsed -and [IO.Path]::GetFileName($parsed.File) -ieq 'Instup.exe' -and (Test-Path -LiteralPath $parsed.File) -and -not $paths.Contains($parsed.File)){[void]$paths.Add($parsed.File)}}}
    return $paths.ToArray()
}
function Invoke-CoreRemoval {
    foreach($engine in @(Get-InstupPaths)){
        try{Enable-SilentUninstall $engine;[void](Invoke-ProcessChecked -File $engine -Args '/control_panel /instop:uninstall /silent /wait' -WorkingDirectory ([IO.Path]::GetDirectoryName($engine)));Start-Sleep 10}catch{Write-Log "Core uninstall failed from $engine`: $($_.Exception.Message)" WARN}
    }
}
function Invoke-EntryRemoval {
    param([Parameter(Mandatory)]$Entry)
    Write-Log "Processing: $($Entry.DisplayName) $($Entry.DisplayVersion)"
    if($Entry.WindowsInstaller -eq 1 -or $Entry.UninstallString -match '(?i)\bmsiexec(?:\.exe)?\b'){
        $productCode=$null;if($Entry.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$'){$productCode=$Entry.KeyName}elseif($Entry.UninstallString -match '(\{[0-9A-Fa-f-]{36}\})'){$productCode=$Matches[1]}
        if(-not $productCode){Write-Log "MSI product code not found for $($Entry.DisplayName)." WARN;return $false}
        try{[void](Invoke-ProcessChecked -File (Join-Path $env:WINDIR 'System32\msiexec.exe') -Args ('/x {0} /qn /norestart' -f $productCode) -SuccessExitCodes @(0,1605,1614,1641,3010));return $true}catch{Write-Log "MSI uninstall failed for $($Entry.DisplayName)`: $($_.Exception.Message)" WARN;return $false}
    }
    $command=$Entry.QuietUninstallString;if(-not $command){$command=$Entry.UninstallString};if(-not $command){Write-Log "No uninstall command for $($Entry.DisplayName)." WARN;return $false}
    $parsed=Split-CommandLine $command;if($null -eq $parsed){Write-Log "Could not parse uninstall command for $($Entry.DisplayName)." WARN;return $false}
    $file=$parsed.File;$args=$parsed.Args;$name=[IO.Path]::GetFileName($file);if(-not(Test-Path -LiteralPath $file -PathType Leaf)){Write-Log "Uninstaller missing: $file" WARN;return $false}
    if($name -ieq 'Instup.exe'){Enable-SilentUninstall $file;$args='/control_panel /instop:uninstall /silent /wait'}
    elseif($Entry.DisplayName -match '(?i)secure browser' -or $file -match '(?i)avast.*browser'){
        if($args -notmatch '(?i)--uninstall'){$args+=' --uninstall'}
        if($file -match '(?i)\\users\\' -or $args -match '(?i)--user-level'){if($args -notmatch '(?i)--user-level'){$args+=' --user-level'}}elseif($args -notmatch '(?i)--system-level'){$args+=' --system-level'}
        if($args -notmatch '(?i)--force-uninstall'){$args+=' --force-uninstall'}
    }elseif($name -match '(?i)^unins\d*\.exe$'){$args='/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'}elseif(-not $Entry.QuietUninstallString -and $args -notmatch '(?i)(/s\b|/silent\b|/quiet\b|/qn\b|--silent\b|--force-uninstall\b)'){$args+=' /silent /norestart'}
    try{[void](Invoke-ProcessChecked -File $file -Args $args.Trim() -WorkingDirectory ([IO.Path]::GetDirectoryName($file)));return $true}catch{Write-Log "Uninstall failed for $($Entry.DisplayName)`: $($_.Exception.Message)" WARN;return $false}
}
function Get-AvastProcesses { try{return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)^(avast|asw|afw|wsc_proxy)' -or $_.ExecutablePath -match '(?i)\\avast software\\|\\avast\\|\\avast browser\\'})}catch{return @()} }
function Get-AvastServices { try{return @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)^(avast|asw|afw)' -or $_.DisplayName -match '(?i)avast' -or $_.PathName -match '(?i)\\avast software\\|\\avast\\'})}catch{return @()} }
function Get-AvastAppx { try{return @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '(?i)avast' -or $_.PackageFullName -match '(?i)avast' -or $_.Publisher -match '(?i)avast'})}catch{return @()} }
function Get-AvastProvisioned { try{return @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue|Where-Object{$_.DisplayName -match '(?i)avast' -or $_.PackageName -match '(?i)avast'})}catch{return @()} }
function Remove-AvastAppx {
    foreach($package in Get-AvastAppx){try{Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop}catch{try{Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop}catch{Write-Log "AppX removal failed: $($_.Exception.Message)" WARN}}}
    foreach($package in Get-AvastProvisioned){try{Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -AllUsers -ErrorAction Stop|Out-Null}catch{Write-Log "Provisioned AppX removal failed: $($_.Exception.Message)" WARN}}
}
function Remove-Residuals {
    if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue){foreach($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{$_.TaskName -match '(?i)avast' -or $_.TaskPath -match '(?i)avast'})){try{Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop}catch{}}}
    foreach($process in Get-AvastProcesses){try{Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
    Start-Sleep 3
    foreach($root in @($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)|Where-Object{$_}|Select-Object -Unique){$folder=Join-Path $root 'Avast Software';if(Test-Path -LiteralPath $folder){try{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop}catch{$script:RestartNeeded=$true;Write-Log "Folder locked until restart: $folder" WARN}}}
}
function Get-State { return [pscustomobject]@{Entries=@(Get-AvastEntries);Appx=@(Get-AvastAppx);Provisioned=@(Get-AvastProvisioned);Processes=@(Get-AvastProcesses);Services=@(Get-AvastServices)} }

try{
    if($env:OS -ne 'Windows_NT'){throw 'Windows is required.'}
    New-Item -Path $LogDir -ItemType Directory -Force|Out-Null;Set-Status STARTED
    if(-not(Test-Admin)){Write-Log 'Run this Atera script as Local System or an administrator.' ERROR;Set-Status 'FAILED: NOT ADMIN';exit 10}
    Write-Log "Avast removal $Version started on $env:COMPUTERNAME."
    $state=Get-State
    if($state.Entries.Count -eq 0 -and $state.Appx.Count -eq 0 -and $state.Provisioned.Count -eq 0 -and $state.Processes.Count -eq 0 -and $state.Services.Count -eq 0){Write-Log 'No Avast detected.' SUCCESS;Set-Status 'SUCCESS: NOT DETECTED';exit 0}
    $script:SelfDefense=Test-SelfDefense
    for($pass=1;$pass -le 2;$pass++){
        Write-Log "Starting pass $pass."
        foreach($entry in @(Get-AvastEntries|Where-Object{$_.DisplayName -notmatch '(?i)avast\s+(one|free antivirus|antivirus|premium security|internet security|ultimate|premier|pro antivirus)'})){[void](Invoke-EntryRemoval $entry);Start-Sleep 3}
        Invoke-CoreRemoval;Start-Sleep 15
        foreach($entry in @(Get-AvastEntries)){[void](Invoke-EntryRemoval $entry);Start-Sleep 3}
        Remove-AvastAppx;Start-Sleep 10
        $state=Get-State;if($state.Entries.Count -eq 0 -and $state.Appx.Count -eq 0 -and $state.Provisioned.Count -eq 0){break}
    }
    $state=Get-State
    if($state.Entries.Count -eq 0 -and $state.Appx.Count -eq 0 -and $state.Provisioned.Count -eq 0){Remove-Residuals}else{Write-Log 'Skipping residual deletion because Avast is still registered.' WARN}
    Start-Sleep 5;$state=Get-State
    if($state.Entries.Count -gt 0 -or $state.Appx.Count -gt 0 -or $state.Provisioned.Count -gt 0){
        foreach($entry in $state.Entries){Write-Log "Remaining product: $($entry.DisplayName) $($entry.DisplayVersion)" ERROR}
        if($script:SelfDefense){Set-Status 'FAILED: SELF-DEFENSE OR AVAST REMAINS';exit 5}
        Set-Status 'FAILED: AVAST REMAINS';exit 1
    }
    if($state.Processes.Count -gt 0 -or $state.Services.Count -gt 0){$script:RestartNeeded=$true}
    if($script:RestartNeeded){Write-Log 'Restart required to unload remaining components.' WARN;Set-Status 'SUCCESS: RESTART REQUIRED';if($Restart){Restart-Computer -Force;exit 0};exit 3010}
    Write-Log 'All detected Avast applications were removed.' SUCCESS;Set-Status 'SUCCESS: REMOVED';exit 0
}catch{try{Write-Log "Unexpected failure: $($_.Exception.Message)" ERROR}catch{};Set-Status "FAILED: $($_.Exception.Message)";exit 20}
