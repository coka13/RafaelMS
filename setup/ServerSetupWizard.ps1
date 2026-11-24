<#
.SYNOPSIS
    RafaelMS (HeavenMS) server setup wizard.

.DESCRIPTION
    Prepares a Windows machine to run the game server:
      1. Checks / installs Java 8 JDK and MySQL (via winget when missing)
      2. Starts the local MySQL service if it is stopped
      3. Imports sql\db_database.sql, db_drops.sql, db_shopupdate.sql in order
         (an existing 'heavenms' database is backed up with mysqldump before it is replaced)
      4. Relaxes MySQL sql_mode (HeavenMS relies on zero dates / non-strict inserts)
      5. Creates a dedicated DB account using mysql_native_password, which the
         bundled Connector/J 5.1.6 driver needs on MySQL 8
      6. Writes DB_URL / DB_USER / DB_PASS / HOST / LOCALSERVER into config.yaml
      7. Compiles src\ into dist\ when needed
      8. Points launch.bat at the detected JDK and sets the JVM heap
      9. Opens Windows Firewall for the login port (8484) and every channel port
     10. Verifies the database login using the server's own JDBC driver

    Run without parameters for the GUI wizard. Use -Silent for an unattended run.

.EXAMPLE
    .\setup-server.bat
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup\ServerSetupWizard.ps1 -Silent -AdminPassword "rootpw" -ServerIp 203.0.113.10
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [string]$MySqlHost = 'localhost',
    [int]$MySqlPort = 3306,
    [string]$AdminUser = 'root',
    [string]$AdminPassword = '',
    [string]$DbUser = 'heavenms',
    [string]$DbPassword = '',
    [switch]$UseAdminForServer,
    [ValidateSet('Keep', 'Recreate')][string]$ExistingDatabase = 'Keep',
    [string]$ServerIp = '127.0.0.1',
    [switch]$SkipShopUpdate,
    [switch]$SkipSqlMode,
    [switch]$SkipFirewall,
    [ValidateSet('Auto', 'Always', 'Never')][string]$Build = 'Auto',
    [switch]$SkipLaunchScript,
    [int]$HeapMB = 2048,
    [switch]$SkipDriverTest,
    [switch]$NoElevate,
    [switch]$HideConsole
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# --------------------------------------------------------------------------------------------
# Elevation (firewall rules and starting services need administrator rights)
# --------------------------------------------------------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } else {
            $argList += "-$k"
            $argList += '"' + ([string]$v -replace '"', '\"') + '"'
        }
    }
    if ($Silent) { $argList += '-NoElevate' }  # never loop
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -PassThru
        if ($Silent) { $p.WaitForExit(); exit $p.ExitCode }
        exit 0
    } catch {
        Write-Warning 'Administrator rights were not granted. Continuing anyway: firewall rules and starting the MySQL service will be skipped.'
    }
}

# --------------------------------------------------------------------------------------------
# Paths and state
# --------------------------------------------------------------------------------------------
$Root       = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.yaml'
$LaunchBat  = Join-Path $Root 'launch.bat'
$SqlDir     = Join-Path $Root 'sql'
$DistDir    = Join-Path $Root 'dist'
$CoresDir   = Join-Path $Root 'cores'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir     = Join-Path $PSScriptRoot 'logs'
$BackupDir  = Join-Path $PSScriptRoot 'backups'
$Work       = Join-Path $env:TEMP ("rafaelms-setup-" + [guid]::NewGuid().ToString('N'))
$DbName     = 'heavenms'   # hard-coded by the sql\ scripts (USE `heavenms`)
$FwGroup    = 'RafaelMS Server'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding $false

New-Item -ItemType Directory -Force -Path $LogDir, $Work | Out-Null
$script:LogFile  = Join-Path $LogDir "setup-$Stamp.log"
$script:LogBox   = $null
$script:Gui      = $false
$script:Progress = $null
$script:Warnings = New-Object System.Collections.Generic.List[string]

$S = @{
    MySqlExe         = $null
    MySqlDump        = $null
    Jdk              = $null
    MySqlHost        = $MySqlHost
    MySqlPort        = $MySqlPort
    AdminUser        = $AdminUser
    AdminPassword    = $AdminPassword
    UseDedicated     = -not $UseAdminForServer
    DbUser           = $DbUser
    DbPassword       = $DbPassword
    ExistingDatabase = $ExistingDatabase
    ShopUpdate       = -not $SkipShopUpdate
    RelaxSqlMode     = -not $SkipSqlMode
    ServerIp         = $ServerIp
    Firewall         = -not $SkipFirewall
    Build            = $false
    FixLaunch        = -not $SkipLaunchScript
    HeapMB           = $HeapMB
    DriverTest       = -not $SkipDriverTest
    ServerVersion    = ''
}

# --------------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------------
function Pump {
    if ($script:Gui) { [System.Windows.Forms.Application]::DoEvents() }
}

function Write-Log {
    param([string]$Message, [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info')
    $prefix = switch ($Level) {
        'Ok'    { '  [ OK ] ' }
        'Warn'  { '  [WARN] ' }
        'Error' { '  [FAIL] ' }
        'Step'  { '' }
        default { '         ' }
    }
    $line = if ($Level -eq 'Step') { "`r`n>> $Message" } else { $prefix + $Message }
    if ($Level -eq 'Warn') { $script:Warnings.Add($Message) }
    try { Add-Content -Path $script:LogFile -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $line.TrimStart()) } catch { }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        Pump
    } else {
        $color = switch ($Level) { 'Ok' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Step' { 'Cyan' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
}

function New-TempFile([string]$Extension = '.tmp') {
    Join-Path $Work ([guid]::NewGuid().ToString('N') + $Extension)
}

function Invoke-Proc {
    <# Runs a process with redirected output while keeping the GUI responsive. #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string]$Arguments,
        [string]$StdinFile,
        [string]$WorkDir = $Root
    )
    $out = New-TempFile '.out'
    $err = New-TempFile '.err'
    $sp = @{
        FilePath               = $File
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        NoNewWindow            = $true
        PassThru               = $true
        WorkingDirectory       = $WorkDir
    }
    if ($Arguments) { $sp.ArgumentList = $Arguments }
    if ($StdinFile) { $sp.RedirectStandardInput = $StdinFile }
    $p = Start-Process @sp
    $null = $p.Handle   # caches the handle so ExitCode is available afterwards
    while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 100 }
    $p.WaitForExit()
    $o = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
    $e = if (Test-Path $err) { [IO.File]::ReadAllText($err) } else { '' }
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Code = $p.ExitCode; Out = $o; Err = $e }
}

function Get-Tail([string]$Text, [int]$Lines = 25) {
    $all = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($all.Count -le $Lines) { return ($all -join "`r`n") }
    ($all[($all.Count - $Lines)..($all.Count - 1)]) -join "`r`n"
}

function New-RandomPassword([int]$Length = 20) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] $Length
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function ConvertTo-SqlString([string]$Value) {
    "'" + ($Value -replace '\\', '\\' -replace "'", "\'") + "'"
}

function ConvertTo-YamlString([string]$Value) {
    '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Test-IPv4([string]$Value) {
    $parts = $Value.Split('.')
    if ($parts.Count -ne 4) { return $false }
    foreach ($p in $parts) {
        if ($p -notmatch '^\d{1,3}$' -or [int]$p -gt 255) { return $false }
    }
    $true
}

function Test-IsLocalHost([string]$HostName) {
    @('localhost', '127.0.0.1', '::1', '.') -contains $HostName.ToLowerInvariant()
}

# --------------------------------------------------------------------------------------------
# Detection
# --------------------------------------------------------------------------------------------
function Get-JavaVersion([string]$JavaExe) {
    try {
        $r = Invoke-Proc -File $JavaExe -Arguments '-version'
        $m = [regex]::Match($r.Err + $r.Out, 'version "([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    ''
}

function Find-Jdk {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:JAVA_HOME) { $cands.Add($env:JAVA_HOME) }
    $patterns = @(
        "$env:ProgramFiles\Java\jdk1.8*",
        "$env:ProgramFiles\Eclipse Adoptium\jdk-8*",
        "$env:ProgramFiles\Zulu\zulu-8*",
        "$env:ProgramFiles\Amazon Corretto\jdk1.8*",
        "${env:ProgramFiles(x86)}\Java\jdk1.8*"
    )
    foreach ($pat in $patterns) {
        Get-ChildItem -Path $pat -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object { $cands.Add($_.FullName) }
    }
    $javac = Get-Command javac.exe -ErrorAction SilentlyContinue
    if ($javac) { $cands.Add((Split-Path (Split-Path $javac.Source))) }

    foreach ($c in ($cands | Select-Object -Unique)) {
        $jc = Join-Path $c 'bin\javac.exe'
        $j  = Join-Path $c 'bin\java.exe'
        if ((Test-Path $jc) -and (Test-Path $j)) {
            $ver = Get-JavaVersion $j
            if ($ver -like '1.8*') {
                return [pscustomobject]@{ Home = $c; Bin = (Join-Path $c 'bin'); Java = $j; Javac = $jc; Version = $ver }
            }
        }
    }
    $null
}

function Get-DbServices {
    @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'mysql|maria' -or $_.PathName -match 'mysqld|mariadbd' })
}

function Find-MySqlTool([string]$Name) {
    $c = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $pats = New-Object System.Collections.Generic.List[string]
    foreach ($svc in Get-DbServices) {
        $m = [regex]::Match([string]$svc.PathName, '^"?([^"]+?\.exe)')
        if ($m.Success) { $pats.Add((Join-Path (Split-Path $m.Groups[1].Value) "$Name.exe")) }
    }
    $pats.Add("$env:ProgramFiles\MySQL\MySQL Server *\bin\$Name.exe")
    $pats.Add("$env:ProgramFiles\MariaDB *\bin\$Name.exe")
    $pats.Add("${env:ProgramFiles(x86)}\MySQL\MySQL Server *\bin\$Name.exe")
    $pats.Add("C:\xampp\mysql\bin\$Name.exe")
    foreach ($p in $pats) {
        $f = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    $null
}

function Get-MissingServerFiles {
    $need = @('config.yaml', 'launch.bat', 'sql\db_database.sql', 'sql\db_drops.sql', 'sql\db_shopupdate.sql', 'src', 'wz', 'scripts')
    $missing = @($need | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
    if (-not (Get-ChildItem $CoresDir -Filter 'mysql-connector*.jar' -ErrorAction SilentlyContinue)) { $missing += 'cores\mysql-connector*.jar' }
    $missing
}

function Get-BuildStatus {
    $main = Join-Path $DistDir 'net\server\Server.class'
    if (-not (Test-Path $main)) { return [pscustomobject]@{ Needed = $true; Reason = 'dist\ has no compiled server yet' } }
    $built = (Get-Item $main).LastWriteTime
    $newer = @(Get-ChildItem (Join-Path $Root 'src') -Recurse -Filter *.java | Where-Object { $_.LastWriteTime -gt $built })
    if ($newer.Count -gt 0) { return [pscustomobject]@{ Needed = $true; Reason = "$($newer.Count) source file(s) changed since the last build" } }
    [pscustomobject]@{ Needed = $false; Reason = 'dist\ is up to date' }
}

function Get-WorldLayout {
    <# Reads worlds/channels from config.yaml. Channel port = 7575 + world*100 + (channel-1). #>
    $lines = [IO.File]::ReadAllLines($ConfigPath)
    $channels = New-Object System.Collections.Generic.List[int]
    $inWorlds = $false
    $worldCount = 1
    foreach ($l in $lines) {
        if ($l -match '^worlds:') { $inWorlds = $true; continue }
        if ($l -match '^[^\s#]') { $inWorlds = $false }
        if ($inWorlds -and $l -match '^\s+channels:\s*(\d+)') { $channels.Add([int]$Matches[1]) }
        if ($l -match '^\s+WORLDS:\s*(\d+)') { $worldCount = [int]$Matches[1] }
    }
    $n = [Math]::Min($worldCount, $channels.Count)
    $list = @()
    for ($w = 0; $w -lt $n; $w++) {
        $first = 7575 + $w * 100
        $list += [pscustomobject]@{ World = $w; Channels = $channels[$w]; First = $first; Last = $first + $channels[$w] - 1 }
    }
    $list
}

function Get-LocalIPv4 {
    try {
        @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Sort-Object InterfaceMetric | Select-Object -ExpandProperty IPAddress)
    } catch { @() }
}

# --------------------------------------------------------------------------------------------
# MySQL access (credentials go through a temporary option file, never the command line)
# --------------------------------------------------------------------------------------------
function Invoke-MySql {
    param([string]$Sql, [string]$SqlFile, [string]$Database, [string]$Tool = $S.MySqlExe, [string]$ExtraArgs = '')
    $esc = { param($v) '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"' }
    $cnf = New-TempFile '.cnf'
    $content = "[client]`r`nuser=$(& $esc $S.AdminUser)`r`npassword=$(& $esc $S.AdminPassword)`r`nhost=$($S.MySqlHost)`r`nport=$($S.MySqlPort)`r`n"
    [IO.File]::WriteAllText($cnf, $content, $Utf8NoBom)
    $tmpSql = $null
    if ($Sql) {
        $tmpSql = New-TempFile '.sql'
        [IO.File]::WriteAllText($tmpSql, $Sql, $Utf8NoBom)
        $SqlFile = $tmpSql
    }
    $cli = "--defaults-extra-file=`"$cnf`" --protocol=TCP"
    if ($Tool -eq $S.MySqlExe) { $cli += ' --batch --skip-column-names --default-character-set=utf8' }
    if ($ExtraArgs) { $cli += " $ExtraArgs" }
    if ($Database) { $cli += " $Database" }
    try {
        Invoke-Proc -File $Tool -Arguments $cli -StdinFile $SqlFile
    } finally {
        Remove-Item $cnf -Force -ErrorAction SilentlyContinue
        if ($tmpSql) { Remove-Item $tmpSql -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MySqlError($Result) {
    $lines = @($Result.Err -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\[Warning\]' })
    if ($lines.Count) { $lines -join ' ' } else { "exit code $($Result.Code)" }
}

function Test-AdminConnection {
    if (-not $S.MySqlExe) { throw 'mysql.exe was not found.' }
    $r = Invoke-MySql -Sql 'SELECT VERSION();'
    if ($r.Code -ne 0) { throw (Get-MySqlError $r) }
    $S.ServerVersion = $r.Out.Trim()
    $S.ServerVersion
}

function Get-DbState {
    $state = [pscustomobject]@{ Exists = $false; Complete = $false; Tables = 0; Accounts = 0; Characters = 0 }
    $r = Invoke-MySql -Sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DbName';"
    if ($r.Code -ne 0) { throw (Get-MySqlError $r) }
    $r2 = Invoke-MySql -Sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DbName';"
    $state.Exists = ($r2.Out.Trim() -eq '1')
    $state.Tables = [int]$r.Out.Trim()
    if ($state.Tables -gt 0) {
        $r3 = Invoke-MySql -Sql "SELECT (SELECT COUNT(*) FROM $DbName.accounts), (SELECT COUNT(*) FROM $DbName.characters), (SELECT COUNT(*) FROM $DbName.drop_data);"
        if ($r3.Code -eq 0) {
            $v = $r3.Out.Trim() -split '\s+'
            $state.Accounts = [int]$v[0]; $state.Characters = [int]$v[1]
            $state.Complete = ([int]$v[2] -gt 0)
        }
    }
    $state
}

function Test-IsMariaDb { $S.ServerVersion -match 'MariaDB' }
function Get-MySqlMajor {
    $m = [regex]::Match($S.ServerVersion, '^(\d+)')
    if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }
}

# --------------------------------------------------------------------------------------------
# Setup steps
# --------------------------------------------------------------------------------------------
function Step-Prerequisites {
    Write-Log 'Checking prerequisites' Step
    $missing = @(Get-MissingServerFiles)
    if ($missing.Count) { throw "Server files missing under ${Root}: $($missing -join ', ')" }
    Write-Log "Server folder: $Root" Ok

    if (-not $S.Jdk) { $S.Jdk = Find-Jdk }
    if ($S.Jdk) { Write-Log "Java $($S.Jdk.Version) JDK: $($S.Jdk.Home)" Ok }
    else { Write-Log 'No Java 8 JDK found. The server cannot be built, tested or launched until one is installed.' Warn }

    if (-not $S.MySqlExe) { $S.MySqlExe = Find-MySqlTool 'mysql' }
    if (-not $S.MySqlDump) { $S.MySqlDump = Find-MySqlTool 'mysqldump' }
    if (-not $S.MySqlExe) { throw 'mysql.exe (MySQL client) was not found. Install MySQL or MariaDB first.' }
    Write-Log "MySQL client: $($S.MySqlExe)" Ok
    if (-not $IsAdmin) { Write-Log 'Not running as administrator: firewall rules and service start will be skipped.' Warn }
}

function Step-StartService {
    if (-not (Test-IsLocalHost $S.MySqlHost)) { return }
    $svcs = @(Get-DbServices)
    if (-not $svcs.Count) { return }
    if ($svcs | Where-Object { $_.State -eq 'Running' }) { return }
    Write-Log 'Starting the MySQL service' Step
    $svc = $svcs[0]
    if (-not $IsAdmin) { Write-Log "Service '$($svc.Name)' is stopped and starting it needs administrator rights." Warn; return }
    if ($svc.StartMode -eq 'Disabled') { Set-Service -Name $svc.Name -StartupType Automatic }
    Start-Service -Name $svc.Name
    (Get-Service -Name $svc.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
    Write-Log "Service '$($svc.Name)' is running" Ok
}

function Step-Connect {
    Write-Log "Connecting to MySQL at $($S.MySqlHost):$($S.MySqlPort) as '$($S.AdminUser)'" Step
    $v = Test-AdminConnection
    Write-Log "Connected, server version $v" Ok
}

function Step-Database {
    Write-Log "Database '$DbName'" Step
    $state = Get-DbState
    $import = $true
    if ($state.Tables -gt 0) {
        Write-Log ("Found existing database: {0} tables, {1} accounts, {2} characters" -f $state.Tables, $state.Accounts, $state.Characters)
        if ($S.ExistingDatabase -eq 'Keep' -and $state.Complete) {
            Write-Log 'Keeping existing data (SQL import skipped)' Ok
            $import = $false
        } else {
            if ($S.ExistingDatabase -eq 'Keep') { Write-Log 'Existing database looks incomplete (no drop data), so it will be re-imported.' Warn }
            Step-Backup
        }
    }
    if (-not $import) { return }

    $files = @('db_database.sql', 'db_drops.sql')
    if ($S.ShopUpdate) { $files += 'db_shopupdate.sql' }
    foreach ($f in $files) {
        $src = Join-Path $SqlDir $f
        # Strip a UTF-8 BOM so the first statement is not mangled
        $bytes = [IO.File]::ReadAllBytes($src)
        $tmp = New-TempFile '.sql'
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $fs = [IO.File]::Create($tmp); $fs.Write($bytes, 3, $bytes.Length - 3); $fs.Close()
        } else {
            [IO.File]::WriteAllBytes($tmp, $bytes)
        }
        Write-Log "Importing $f ($([Math]::Round($bytes.Length / 1KB)) KB)..."
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-MySql -SqlFile $tmp
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($r.Code -ne 0) { throw "Import of $f failed: $(Get-MySqlError $r)" }
        Write-Log ("Imported {0} in {1:N1}s" -f $f, $sw.Elapsed.TotalSeconds) Ok
    }
    $after = Get-DbState
    Write-Log "Database now has $($after.Tables) tables" Ok
}

function Step-SchemaMigrations {
    Write-Log 'Database schema migrations' Step
    $r = Invoke-MySql -Sql "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$DbName' AND TABLE_NAME='accounts' AND COLUMN_NAME='webregistered';"
    if ($r.Code -ne 0) { throw (Get-MySqlError $r) }
    if ($r.Out.Trim() -eq '0') {
        $r = Invoke-MySql -Sql "ALTER TABLE $DbName.accounts ADD COLUMN webregistered TINYINT(1) NOT NULL DEFAULT 0 AFTER email;"
        if ($r.Code -ne 0) { throw "Could not add accounts.webregistered: $(Get-MySqlError $r)" }
        Write-Log 'Added accounts.webregistered for web account registration' Ok
    } else {
        Write-Log 'Schema is up to date' Ok
    }
}

function Step-Backup {
    if (-not $S.MySqlDump) { throw "mysqldump.exe was not found, so the existing '$DbName' database cannot be backed up. Choose 'Keep existing data' or install the MySQL client tools." }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $file = Join-Path $BackupDir "$DbName-$Stamp.sql"
    Write-Log "Backing up current database to $file ..."
    $r = Invoke-MySql -Tool $S.MySqlDump -ExtraArgs "--single-transaction --routines --triggers --default-character-set=utf8 --result-file=`"$file`" --databases $DbName"
    if ($r.Code -ne 0 -or -not (Test-Path $file)) { throw "Backup failed, nothing was changed: $(Get-MySqlError $r)" }
    Write-Log ("Backup written ({0:N1} MB)" -f ((Get-Item $file).Length / 1MB)) Ok
}

function Step-SqlMode {
    if (-not $S.RelaxSqlMode) { return }
    Write-Log 'MySQL sql_mode' Step
    $mode = 'NO_ENGINE_SUBSTITUTION'
    if (-not (Test-IsMariaDb) -and (Get-MySqlMajor) -ge 8) {
        $r = Invoke-MySql -Sql "SET PERSIST sql_mode = '$mode';"
        if ($r.Code -ne 0) { Write-Log "Could not set sql_mode: $(Get-MySqlError $r)" Warn; return }
        Write-Log "sql_mode set to $mode (persisted across MySQL restarts)" Ok
    } else {
        $r = Invoke-MySql -Sql "SET GLOBAL sql_mode = '$mode';"
        if ($r.Code -ne 0) { Write-Log "Could not set sql_mode: $(Get-MySqlError $r)" Warn; return }
        Write-Log "sql_mode set to $mode until the next MySQL restart." Ok
        Write-Log "To make it permanent, add  sql_mode=$mode  under [mysqld] in my.ini." Warn
    }
}

function Step-DbAccount {
    Write-Log 'Game server database account' Step
    if (-not $S.UseDedicated) {
        Write-Log "The server will log in as the admin account '$($S.AdminUser)'."
        if (-not (Test-IsMariaDb) -and (Get-MySqlMajor) -ge 8) {
            $r = Invoke-MySql -Sql ("SELECT plugin FROM mysql.user WHERE user=" + (ConvertTo-SqlString $S.AdminUser) + " LIMIT 1;")
            if ($r.Code -eq 0 -and $r.Out.Trim() -eq 'caching_sha2_password') {
                Write-Log "'$($S.AdminUser)' uses caching_sha2_password, which the bundled JDBC driver (Connector/J 5.1.6) cannot use. Prefer a dedicated account." Warn
            }
        }
        return
    }
    if ([string]::IsNullOrEmpty($S.DbPassword)) { $S.DbPassword = New-RandomPassword }
    $hosts = if (Test-IsLocalHost $S.MySqlHost) { @('localhost', '127.0.0.1') } else { @('%') }
    $u = ConvertTo-SqlString $S.DbUser
    $p = ConvertTo-SqlString $S.DbPassword
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $hosts) {
        $acct = "$u@'$h'"
        if (Test-IsMariaDb) {
            [void]$sb.AppendLine("CREATE USER IF NOT EXISTS $acct IDENTIFIED BY $p;")
            [void]$sb.AppendLine("ALTER USER $acct IDENTIFIED BY $p;")
        } else {
            [void]$sb.AppendLine("CREATE USER IF NOT EXISTS $acct IDENTIFIED WITH mysql_native_password BY $p;")
            [void]$sb.AppendLine("ALTER USER $acct IDENTIFIED WITH mysql_native_password BY $p;")
        }
        [void]$sb.AppendLine("GRANT ALL PRIVILEGES ON ``$DbName``.* TO $acct;")
    }
    [void]$sb.AppendLine('FLUSH PRIVILEGES;')
    $r = Invoke-MySql -Sql $sb.ToString()
    if ($r.Code -ne 0) { throw "Creating account '$($S.DbUser)' failed: $(Get-MySqlError $r)" }
    Write-Log "Account '$($S.DbUser)'@($($hosts -join ', ')) ready with full rights on '$DbName' (mysql_native_password)" Ok
}

function Step-Config {
    Write-Log 'config.yaml' Step
    $raw = [IO.File]::ReadAllBytes($ConfigPath)
    $hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
    $text = [IO.File]::ReadAllText($ConfigPath)
    $backup = "$ConfigPath.bak-$Stamp"
    Copy-Item $ConfigPath $backup

    $user = if ($S.UseDedicated) { $S.DbUser } else { $S.AdminUser }
    $pass = if ($S.UseDedicated) { $S.DbPassword } else { $S.AdminPassword }
    $url  = "jdbc:mysql://$($S.MySqlHost):$($S.MySqlPort)/$DbName" + '?characterEncoding=UTF-8&useSSL=false'
    $local = if ($S.ServerIp -like '127.*') { 'true' } else { 'false' }

    $values = [ordered]@{
        DB_URL      = ConvertTo-YamlString $url
        DB_USER     = ConvertTo-YamlString $user
        DB_PASS     = ConvertTo-YamlString $pass
        HOST        = $S.ServerIp
        LOCALSERVER = $local
    }
    foreach ($key in $values.Keys) {
        $rx = New-Object System.Text.RegularExpressions.Regex ('(?m)^([ \t]*' + $key + ':)[^\r\n]*')
        if (-not $rx.IsMatch($text)) { throw "config.yaml has no '${key}:' entry." }
        $val = $values[$key]
        $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + ' ' + $val }, 1)
    }
    $enc = if ($hasBom) { New-Object System.Text.UTF8Encoding $true } else { $Utf8NoBom }
    [IO.File]::WriteAllText($ConfigPath, $text, $enc)
    Write-Log "DB_URL=$url, DB_USER=$user, DB_PASS=(hidden), HOST=$($S.ServerIp), LOCALSERVER=$local" Ok
    Write-Log "Previous file saved as $(Split-Path $backup -Leaf)"
}

function Step-Build {
    if (-not $S.Build) { return }
    Write-Log 'Compiling the server (src -> dist)' Step
    if (-not $S.Jdk) { throw 'Cannot build: no Java 8 JDK found.' }
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    $list = New-TempFile '.txt'
    $files = Get-ChildItem (Join-Path $Root 'src') -Recurse -Filter *.java | ForEach-Object { '"' + ($_.FullName -replace '\\', '/') + '"' }
    [IO.File]::WriteAllLines($list, [string[]]$files, [Text.Encoding]::Default)
    Write-Log "Compiling $($files.Count) source files with $($S.Jdk.Version), this can take a minute..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Proc -File $S.Jdk.Javac -Arguments "-encoding UTF-8 -nowarn -d `"$DistDir`" -cp `"$CoresDir\*`" `"@$list`""
    if ($r.Code -ne 0) {
        Write-Log (Get-Tail ($r.Out + "`n" + $r.Err) 30) Error
        throw 'javac reported errors (see above).'
    }
    Write-Log ("Build finished in {0:N0}s" -f $sw.Elapsed.TotalSeconds) Ok
}

function Step-LaunchScript {
    if (-not $S.FixLaunch) { return }
    Write-Log 'launch.bat' Step
    if (-not $S.Jdk) { Write-Log 'No JDK found, launch.bat left unchanged.' Warn; return }
    $text = [IO.File]::ReadAllText($LaunchBat)
    $orig = $text
    $pathLine = "set PATH=$($S.Jdk.Bin);%PATH%"
    $rxPath = New-Object System.Text.RegularExpressions.Regex '(?im)^set PATH=[^\r\n]*'
    if ($rxPath.IsMatch($text)) {
        $text = $rxPath.Replace($text, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $pathLine }, 1)
    } else {
        $text = $pathLine + "`r`n" + $text
    }
    $heap = "-Xmx$($S.HeapMB)m"
    $text = [regex]::Replace($text, '-Xmx\d+[kKmMgG]', [System.Text.RegularExpressions.MatchEvaluator] { param($m) $heap })
    if ($text -ne $orig) {
        Copy-Item $LaunchBat "$LaunchBat.bak-$Stamp"
        [IO.File]::WriteAllText($LaunchBat, $text, [Text.Encoding]::ASCII)
        Write-Log "launch.bat now uses $($S.Jdk.Bin) with $heap (previous file saved as launch.bat.bak-$Stamp)" Ok
    } else {
        Write-Log 'launch.bat already correct' Ok
    }
}

function Step-Firewall {
    if (-not $S.Firewall) { return }
    Write-Log 'Windows Firewall' Step
    $layout = @(Get-WorldLayout)
    if (-not $IsAdmin) {
        Write-Log 'Skipped (needs administrator rights). Re-run the wizard as administrator, or open these TCP ports manually:' Warn
        Write-Log ('80, 8484, ' + (($layout | ForEach-Object { "$($_.First)-$($_.Last)" }) -join ', '))
        return
    }
    Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'RafaelMS Login server (TCP 8484)' -Group $FwGroup -Direction Inbound `
        -Action Allow -Protocol TCP -LocalPort 8484 -Profile Any | Out-Null
    Write-Log 'Inbound TCP 8484 (login) allowed' Ok
    New-NetFirewallRule -DisplayName 'RafaelMS Registration page (TCP 80)' -Group $FwGroup -Direction Inbound `
        -Action Allow -Protocol TCP -LocalPort 80 -Profile Any | Out-Null
    Write-Log 'Inbound TCP 80 (registration page) allowed' Ok
    foreach ($w in $layout) {
        $range = if ($w.First -eq $w.Last) { "$($w.First)" } else { "$($w.First)-$($w.Last)" }
        New-NetFirewallRule -DisplayName "RafaelMS World $($w.World) channels (TCP $range)" -Group $FwGroup -Direction Inbound `
            -Action Allow -Protocol TCP -LocalPort $range -Profile Any | Out-Null
        Write-Log "Inbound TCP $range (world $($w.World), $($w.Channels) channels) allowed" Ok
    }
    if ($S.ServerIp -notlike '127.*') {
        Write-Log 'Players outside your network also need these ports forwarded on your router.'
    }
}

function Step-DriverTest {
    if (-not $S.DriverTest) { return }
    Write-Log 'Testing the database login with the server''s JDBC driver' Step
    if (-not $S.Jdk) { Write-Log 'Skipped: no JDK.' Warn; return }
    $dir = Join-Path $Work 'dbcheck'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $java = @'
import java.sql.*;
public class DbCheck {
    public static void main(String[] a) {
        try {
            Class.forName("com.mysql.jdbc.Driver");
            try (Connection c = DriverManager.getConnection(System.getenv("HMS_DB_URL"), System.getenv("HMS_DB_USER"), System.getenv("HMS_DB_PASS"));
                 Statement s = c.createStatement();
                 ResultSet r = s.executeQuery("SELECT COUNT(*) FROM accounts")) {
                r.next();
                System.out.println("OK accounts=" + r.getLong(1));
            }
        } catch (Throwable t) {
            System.out.println("FAIL " + t);
            System.exit(1);
        }
    }
}
'@
    [IO.File]::WriteAllText((Join-Path $dir 'DbCheck.java'), $java, $Utf8NoBom)
    $r = Invoke-Proc -File $S.Jdk.Javac -Arguments "-d `"$dir`" `"$dir\DbCheck.java`"" -WorkDir $dir
    if ($r.Code -ne 0) { Write-Log "Could not compile the test: $(Get-Tail $r.Err 5)" Warn; return }

    $env:HMS_DB_URL  = "jdbc:mysql://$($S.MySqlHost):$($S.MySqlPort)/$DbName" + '?characterEncoding=UTF-8&useSSL=false'
    $env:HMS_DB_USER = if ($S.UseDedicated) { $S.DbUser } else { $S.AdminUser }
    $env:HMS_DB_PASS = if ($S.UseDedicated) { $S.DbPassword } else { $S.AdminPassword }
    try {
        $r = Invoke-Proc -File $S.Jdk.Java -Arguments "-cp `"$dir;$CoresDir\*`" DbCheck" -WorkDir $dir
    } finally {
        Remove-Item Env:HMS_DB_URL, Env:HMS_DB_USER, Env:HMS_DB_PASS -ErrorAction SilentlyContinue
    }
    $out = ($r.Out + $r.Err).Trim()
    if ($r.Code -eq 0 -and $out -match 'OK accounts=(\d+)') {
        Write-Log "The server can log in to the database ($($Matches[1]) accounts)" Ok
    } else {
        Write-Log "The server's driver could not connect: $(Get-Tail $out 3)" Error
        if ($out -match 'authentication|Access denied|caching_sha2') {
            Write-Log 'Use a dedicated account (it is created with mysql_native_password, which the bundled driver understands).'
        }
        throw 'Database login test failed.'
    }
}

function Step-Ports {
    $ports = @(8484) + @(Get-WorldLayout | ForEach-Object { $_.First..$_.Last })
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort })
    if ($busy.Count) {
        $desc = $busy | ForEach-Object {
            $pn = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            "$($_.LocalPort) ($pn)"
        } | Select-Object -Unique
        Write-Log "Ports already in use: $($desc -join ', '). Stop that program (or a running server) before launching." Warn
    }
}

function Invoke-Setup {
    $script:Warnings.Clear()
    Write-Log "RafaelMS server setup - log file: $script:LogFile"
    $steps = @(
        @{ Name = 'Prerequisites';   Fn = { Step-Prerequisites } },
        @{ Name = 'MySQL service';   Fn = { Step-StartService } },
        @{ Name = 'Connect';         Fn = { Step-Connect } },
        @{ Name = 'Database';        Fn = { Step-Database } },
        @{ Name = 'Schema migration'; Fn = { Step-SchemaMigrations } },
        @{ Name = 'sql_mode';        Fn = { Step-SqlMode } },
        @{ Name = 'DB account';      Fn = { Step-DbAccount } },
        @{ Name = 'config.yaml';     Fn = { Step-Config } },
        @{ Name = 'Build';           Fn = { Step-Build } },
        @{ Name = 'launch.bat';      Fn = { Step-LaunchScript } },
        @{ Name = 'Firewall';        Fn = { Step-Firewall } },
        @{ Name = 'Driver test';     Fn = { Step-DriverTest } },
        @{ Name = 'Ports';           Fn = { Step-Ports } }
    )
    $ok = $true
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ($script:Progress) { $script:Progress.Value = [int](100 * $i / $steps.Count); Pump }
        try {
            & $steps[$i].Fn
        } catch {
            Write-Log "$($steps[$i].Name): $($_.Exception.Message)" Error
            $ok = $false
            break
        }
    }
    if ($script:Progress) { $script:Progress.Value = 100 }

    Write-Log 'Summary' Step
    if ($ok) {
        Write-Log 'Server prerequisites are in place.' Ok
        Write-Log "Start the server with launch.bat (or launchtest.bat). Players connect to $($S.ServerIp)."
        if ($S.UseDedicated) { Write-Log "DB account '$($S.DbUser)' - its password is stored in config.yaml (DB_PASS)." }
    } else {
        Write-Log 'Setup stopped before finishing. Fix the problem above and run the wizard again; completed steps are safe to repeat.' Error
    }
    if ($script:Warnings.Count) {
        Write-Log "$($script:Warnings.Count) warning(s):"
        foreach ($w in @($script:Warnings)) { Write-Log " - $w" }
    }
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Work | Out-Null
    $ok
}

# --------------------------------------------------------------------------------------------
# Silent mode
# --------------------------------------------------------------------------------------------
if ($Silent) {
    $bs = Get-BuildStatus
    $S.Build = switch ($Build) { 'Always' { $true } 'Never' { $false } default { $bs.Needed } }
    $result = Invoke-Setup
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
    if ($result) { exit 0 } else { exit 1 }
}

# --------------------------------------------------------------------------------------------
# GUI wizard
# --------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:Gui = $true

if ($HideConsole) {
    try {
        Add-Type -Name ConsoleWin -Namespace RafaelMS -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        [void][RafaelMS.ConsoleWin]::ShowWindow([RafaelMS.ConsoleWin]::GetConsoleWindow(), 0)
    } catch { }
}

function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object System.Drawing.Size($w, $h) }
function Add-Ctl($Parent, $Type, $Text, $X, $Y, $W, $H) {
    $c = New-Object "System.Windows.Forms.$Type"
    if ($null -ne $Text) { $c.Text = $Text }
    $c.Location = Pt $X $Y
    $c.Size = Sz $W $H
    $Parent.Controls.Add($c)
    $c
}

$fontUi    = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9)
$cOk   = [System.Drawing.Color]::FromArgb(0, 128, 0)
$cBad  = [System.Drawing.Color]::FromArgb(192, 0, 0)
$cWarn = [System.Drawing.Color]::FromArgb(176, 96, 0)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RafaelMS Server Setup'
$form.ClientSize = Sz 820 580
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = $fontUi

# Sidebar
$side = Add-Ctl $form 'Panel' $null 0 0 190 580
$side.BackColor = [System.Drawing.Color]::FromArgb(28, 38, 56)
$brand = Add-Ctl $side 'Label' 'RafaelMS' 20 24 160 30
$brand.ForeColor = [System.Drawing.Color]::White
$brand.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$brandSub = Add-Ctl $side 'Label' 'Server setup' 21 56 160 20
$brandSub.ForeColor = [System.Drawing.Color]::FromArgb(160, 176, 200)
$stepNames = @('1. Requirements', '2. Database', '3. Server', '4. Install')
$stepLabels = @()
for ($i = 0; $i -lt $stepNames.Count; $i++) {
    $l = Add-Ctl $side 'Label' $stepNames[$i] 20 (110 + $i * 32) 160 24
    $stepLabels += $l
}

$header = Add-Ctl $form 'Label' '' 210 14 590 28
$header.Font = $fontTitle
$subHeader = Add-Ctl $form 'Label' '' 211 44 590 20
$subHeader.ForeColor = [System.Drawing.Color]::DimGray

$pages = @()
for ($i = 0; $i -lt 4; $i++) {
    $p = Add-Ctl $form 'Panel' $null 210 74 594 446
    $p.Visible = $false
    $pages += $p
}
$sep = Add-Ctl $form 'Label' $null 190 528 630 2
$sep.BorderStyle = 'Fixed3D'
$btnBack   = Add-Ctl $form 'Button' '< Back' 530 540 85 28
$btnNext   = Add-Ctl $form 'Button' 'Next >' 620 540 85 28
$btnCancel = Add-Ctl $form 'Button' 'Cancel' 715 540 85 28
$btnLaunch = Add-Ctl $form 'Button' 'Start server' 210 540 110 28
$btnConfig = Add-Ctl $form 'Button' 'Open config.yaml' 326 540 130 28
$btnLaunch.Visible = $false
$btnConfig.Visible = $false
$form.AcceptButton = $btnNext

# ---- Page 0: requirements ----
$p0 = $pages[0]
$intro = Add-Ctl $p0 'Label' ('This wizard prepares this PC to host the game server: Java, the MySQL database and its account, ' +
    'config.yaml, the build, launch.bat and Windows Firewall. You can run it again at any time.') 0 0 590 40
$lv = Add-Ctl $p0 'ListView' $null 0 46 590 230
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HeaderStyle = 'Nonclickable'
[void]$lv.Columns.Add('Requirement', 170)
[void]$lv.Columns.Add('Status', 85)
[void]$lv.Columns.Add('Details', 315)
$btnRecheck = Add-Ctl $p0 'Button' 'Check again' 0 288 110 28
$btnInstall = Add-Ctl $p0 'Button' 'Install missing...' 116 288 140 28
$lblReq = Add-Ctl $p0 'Label' '' 0 326 590 110
$lblReq.ForeColor = [System.Drawing.Color]::DimGray

# ---- Page 1: database ----
$p1 = $pages[1]
$g1 = Add-Ctl $p1 'GroupBox' 'MySQL server (admin login, only used during setup)' 0 0 590 112
[void](Add-Ctl $g1 'Label' 'Host:' 12 26 80 20)
$tbHost = Add-Ctl $g1 'TextBox' $S.MySqlHost 96 23 200 23
[void](Add-Ctl $g1 'Label' 'Port:' 312 26 40 20)
$tbPort = Add-Ctl $g1 'TextBox' ([string]$S.MySqlPort) 356 23 70 23
[void](Add-Ctl $g1 'Label' 'Admin user:' 12 56 80 20)
$tbAdmin = Add-Ctl $g1 'TextBox' $S.AdminUser 96 53 200 23
[void](Add-Ctl $g1 'Label' 'Password:' 312 56 60 20)
$tbAdminPw = Add-Ctl $g1 'TextBox' $S.AdminPassword 376 53 200 23
$tbAdminPw.UseSystemPasswordChar = $true
$btnTest = Add-Ctl $g1 'Button' 'Test connection' 96 82 120 25
$lblConn = Add-Ctl $g1 'Label' 'Not tested yet' 226 86 355 20

$g2 = Add-Ctl $p1 'GroupBox' 'Account the game server logs in with' 0 120 590 112
$rbDedicated = Add-Ctl $g2 'RadioButton' 'Create a dedicated account (recommended)' 12 22 300 22
$rbDedicated.Checked = $S.UseDedicated
[void](Add-Ctl $g2 'Label' 'User:' 32 52 40 20)
$tbDbUser = Add-Ctl $g2 'TextBox' $S.DbUser 76 49 140 23
[void](Add-Ctl $g2 'Label' 'Password:' 228 52 60 20)
$tbDbPw = Add-Ctl $g2 'TextBox' $(if ($S.DbPassword) { $S.DbPassword } else { New-RandomPassword }) 292 49 190 23
$btnGen = Add-Ctl $g2 'Button' 'New' 488 48 50 25
$rbAdminAcct = Add-Ctl $g2 'RadioButton' 'Use the admin account above' 12 82 300 22
$rbAdminAcct.Checked = -not $S.UseDedicated

$g3 = Add-Ctl $p1 'GroupBox' "Game database '$DbName'" 0 240 590 200
$lblDb = Add-Ctl $g3 'Label' 'Test the connection to see the current state.' 12 22 570 36
$rbKeep = Add-Ctl $g3 'RadioButton' 'Keep existing data (skip the SQL import)' 12 60 560 22
$rbRecreate = Add-Ctl $g3 'RadioButton' 'Re-create from sql\  (current data is backed up to setup\backups first, then deleted)' 12 84 570 22
if ($S.ExistingDatabase -eq 'Recreate') { $rbRecreate.Checked = $true } else { $rbKeep.Checked = $true }
$rbKeep.Enabled = $false; $rbRecreate.Enabled = $false
$chkShop = Add-Ctl $g3 'CheckBox' 'Also apply db_shopupdate.sql (custom NPC shop goods; needs the bundled WZ files)' 12 116 570 22
$chkShop.Checked = $S.ShopUpdate
$chkSqlMode = Add-Ctl $g3 'CheckBox' 'Relax MySQL sql_mode to NO_ENGINE_SUBSTITUTION (HeavenMS fails on strict mode)' 12 140 570 22
$chkSqlMode.Checked = $S.RelaxSqlMode
$lblDbNote = Add-Ctl $g3 'Label' 'The import takes around 10-30 seconds.' 30 166 550 20
$lblDbNote.ForeColor = [System.Drawing.Color]::DimGray

# ---- Page 2: server ----
$p2 = $pages[2]
$g4 = Add-Ctl $p2 'GroupBox' 'Address players connect to (HOST in config.yaml)' 0 0 590 132
$cbIp = Add-Ctl $g4 'ComboBox' $null 12 24 200 23
[void]$cbIp.Items.Add('127.0.0.1')
foreach ($ip in Get-LocalIPv4) { [void]$cbIp.Items.Add($ip) }
$cbIp.Text = $S.ServerIp
$btnPublic = Add-Ctl $g4 'Button' 'Detect public IP' 220 23 120 25
$lblIp = Add-Ctl $g4 'Label' ('127.0.0.1 = only this PC can play.  A 192.168.x.x / 10.x address = your local network.  ' +
    'Your public IP = players over the internet (also forward the ports below on your router). ' +
    'The client installer must use the same address.') 12 56 570 70
$lblIp.ForeColor = [System.Drawing.Color]::DimGray

$g5 = Add-Ctl $p2 'GroupBox' 'Network ports' 0 140 590 92
$lblPorts = Add-Ctl $g5 'Label' '' 12 22 570 36
$chkFw = Add-Ctl $g5 'CheckBox' 'Allow these ports through Windows Firewall (inbound TCP)' 12 60 560 22
$chkFw.Checked = $S.Firewall

$g6 = Add-Ctl $p2 'GroupBox' 'Build and launch' 0 240 590 200
$chkBuild = Add-Ctl $g6 'CheckBox' 'Compile the server (src -> dist)' 12 22 560 22
$lblBuild = Add-Ctl $g6 'Label' '' 30 44 550 20
$lblBuild.ForeColor = [System.Drawing.Color]::DimGray
$chkLaunch = Add-Ctl $g6 'CheckBox' 'Point launch.bat at the detected JDK' 12 70 560 22
$chkLaunch.Checked = $S.FixLaunch
[void](Add-Ctl $g6 'Label' 'Server memory (MB):' 30 100 120 20)
$numHeap = Add-Ctl $g6 'NumericUpDown' $null 152 98 80 23
$numHeap.Minimum = 512; $numHeap.Maximum = 32768; $numHeap.Increment = 512; $numHeap.Value = $S.HeapMB
$chkTest = Add-Ctl $g6 'CheckBox' 'Test the database login with the server''s own JDBC driver' 12 132 560 22
$chkTest.Checked = $S.DriverTest

# ---- Page 3: install ----
$p3 = $pages[3]
$tbLog = Add-Ctl $p3 'TextBox' '' 0 0 590 412
$tbLog.Multiline = $true; $tbLog.ReadOnly = $true; $tbLog.ScrollBars = 'Vertical'
$tbLog.Font = $fontMono; $tbLog.BackColor = [System.Drawing.Color]::White; $tbLog.WordWrap = $true
$pbar = Add-Ctl $p3 'ProgressBar' $null 0 420 590 18
$script:Progress = $null

# ---- State and logic ----
$script:Page = 0
$script:ConnOk = $false
$script:ConnKey = ''
$script:Running = $false
$script:Done = $false
$script:DbState = $null

$titles = @(
    @('Requirements', 'Software and files the server needs on this PC'),
    @('Database', 'MySQL connection, server account and game data'),
    @('Server', 'Network address, firewall and build'),
    @('Install', 'Review the plan, then click Install')
)

function Update-Checks {
    $lv.Items.Clear()
    $S.Jdk = Find-Jdk
    $S.MySqlExe = Find-MySqlTool 'mysql'
    $S.MySqlDump = Find-MySqlTool 'mysqldump'
    $svcs = @(Get-DbServices)
    $missing = @(Get-MissingServerFiles)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $add = {
        param($name, $ok, $status, $detail)
        $it = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$it.SubItems.Add($status)
        [void]$it.SubItems.Add($detail)
        $it.UseItemStyleForSubItems = $false
        $it.SubItems[1].ForeColor = switch ($ok) { 'ok' { $cOk } 'bad' { $cBad } default { $cWarn } }
        [void]$lv.Items.Add($it)
    }
    & $add 'Administrator rights' $(if ($IsAdmin) { 'ok' } else { 'warn' }) $(if ($IsAdmin) { 'Yes' } else { 'No' }) 'Needed for firewall rules and starting MySQL'
    if ($S.Jdk) { & $add 'Java 8 JDK' 'ok' 'Found' "$($S.Jdk.Version)  $($S.Jdk.Home)" }
    else { & $add 'Java 8 JDK' 'bad' 'Missing' 'Required to build and run the server' }
    if ($S.MySqlExe) { & $add 'MySQL client' 'ok' 'Found' $S.MySqlExe }
    else { & $add 'MySQL client' 'bad' 'Missing' 'mysql.exe is needed to import the database' }
    if ($svcs.Count) {
        $run = @($svcs | Where-Object { $_.State -eq 'Running' })
        $svc = if ($run.Count) { $run[0] } else { $svcs[0] }
        & $add 'MySQL service' $(if ($run.Count) { 'ok' } else { 'warn' }) $svc.State "$($svc.Name) (will be started if needed)"
    } else {
        & $add 'MySQL service' 'warn' 'None' 'No local MySQL/MariaDB service (fine if the DB is on another PC)'
    }
    & $add 'mysqldump' $(if ($S.MySqlDump) { 'ok' } else { 'warn' }) $(if ($S.MySqlDump) { 'Found' } else { 'Missing' }) 'Used to back up an existing database'
    if ($missing.Count) { & $add 'Server files' 'bad' 'Missing' ($missing -join ', ') }
    else { & $add 'Server files' 'ok' 'OK' $Root }
    & $add 'winget' $(if ($winget) { 'ok' } else { 'warn' }) $(if ($winget) { 'Found' } else { 'Missing' }) 'Only needed to install missing software'

    $needInstall = (-not $S.Jdk) -or (-not $S.MySqlExe)
    $btnInstall.Enabled = $needInstall -and [bool]$winget
    $msg = ''
    if ($missing.Count) { $msg = "This wizard must be inside the HeavenMS folder (setup\). Missing: $($missing -join ', ')." }
    elseif ($needInstall -and $winget) { $msg = 'Click "Install missing..." to install Eclipse Temurin 8 JDK and/or MariaDB with winget.' }
    elseif ($needInstall) { $msg = 'Install a Java 8 JDK (adoptium.net) and MySQL 8 (dev.mysql.com), then click "Check again".' }
    else { $msg = 'Everything needed is present. Click Next.' }
    if ($S.Jdk -or $S.MySqlExe) { $msg += "`r`n`r`nNote: the server ships with the MySQL Connector/J 5.1.6 driver. On MySQL 8 the wizard creates the server account with mysql_native_password so this driver can log in." }
    $lblReq.Text = $msg
}

function Install-Missing {
    $form.Cursor = 'WaitCursor'
    try {
        $wg = (Get-Command winget.exe).Source
        $common = '--exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity'
        if (-not $S.Jdk) {
            $lblReq.Text = 'Installing Eclipse Temurin 8 JDK with winget...'; Pump
            $r = Invoke-Proc -File $wg -Arguments "install --id EclipseAdoptium.Temurin.8.JDK --silent $common"
            $jdkInstallOutput = $r.Out + "`r`n" + $r.Err
            if ($r.Code -ne 0 -and $jdkInstallOutput -match 'Installer hash does not match') {
                $fallbackVersion = '8.0.504.1'
                $lblReq.Text = "The latest package has a bad winget hash. Retrying Temurin $fallbackVersion..."; Pump
                $r = Invoke-Proc -File $wg -Arguments "install --id EclipseAdoptium.Temurin.8.JDK --version $fallbackVersion --silent $common"
                $jdkInstallOutput = $r.Out + "`r`n" + $r.Err
            }
            if ($r.Code -ne 0) {
                [void][System.Windows.Forms.MessageBox]::Show("winget could not install the JDK (exit $($r.Code)).`r`n`r`n$(Get-Tail $jdkInstallOutput 8)", 'Install Java', 'OK', 'Error')
            }
        }
        if (-not $S.MySqlExe) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "MariaDB (a MySQL-compatible database) will be installed. Its installer opens and asks you to choose a root password.`r`n`r`nRemember that password: you enter it on the next page of this wizard.",
                'Install database', 'OKCancel', 'Information')
            if ($ans -eq 'OK') {
                $lblReq.Text = 'Installing MariaDB with winget (follow its installer window)...'; Pump
                $r = Invoke-Proc -File $wg -Arguments "install --id MariaDB.Server --interactive --exact --accept-package-agreements --accept-source-agreements"
                if ($r.Code -ne 0) {
                    [void][System.Windows.Forms.MessageBox]::Show("winget could not install MariaDB (exit $($r.Code)).`r`n`r`n$(Get-Tail $r.Out 8)", 'Install database', 'OK', 'Error')
                }
            }
        }
    } finally {
        $form.Cursor = 'Default'
        Update-Checks
    }
}

function Read-DbFields {
    $S.MySqlHost = $tbHost.Text.Trim()
    $port = 0
    if (-not [int]::TryParse($tbPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Port must be a number between 1 and 65535.' }
    $S.MySqlPort = $port
    $S.AdminUser = $tbAdmin.Text.Trim()
    $S.AdminPassword = $tbAdminPw.Text
    if (-not $S.MySqlHost) { throw 'Enter the MySQL host.' }
    if (-not $S.AdminUser) { throw 'Enter the MySQL admin user.' }
}

function Test-ConnectionGui {
    $script:ConnOk = $false
    $rbKeep.Enabled = $false; $rbRecreate.Enabled = $false
    try {
        Read-DbFields
        $lblConn.ForeColor = [System.Drawing.Color]::Black
        $lblConn.Text = 'Connecting...'; Pump
        $form.Cursor = 'WaitCursor'
        $ver = Test-AdminConnection
        $script:DbState = Get-DbState
        $lblConn.ForeColor = $cOk
        $lblConn.Text = "Connected - $(if (Test-IsMariaDb) { 'MariaDB' } else { 'MySQL' }) $ver"
        $script:ConnOk = $true
        $script:ConnKey = "$($S.MySqlHost)|$($S.MySqlPort)|$($S.AdminUser)|$($S.AdminPassword)"
        $st = $script:DbState
        if ($st.Tables -eq 0) {
            $lblDb.Text = "Not found - it will be created and filled from sql\."
            $lblDb.ForeColor = [System.Drawing.Color]::Black
        } elseif (-not $st.Complete) {
            $lblDb.Text = "Exists but looks incomplete ($($st.Tables) tables, no drop data). It will be re-imported (backed up first)."
            $lblDb.ForeColor = $cWarn
            $rbRecreate.Checked = $true
        } else {
            $lblDb.Text = "Already set up: $($st.Tables) tables, $($st.Accounts) accounts, $($st.Characters) characters."
            $lblDb.ForeColor = $cOk
            $rbKeep.Enabled = $true; $rbRecreate.Enabled = $true
        }
    } catch {
        $lblConn.ForeColor = $cBad
        $msg = $_.Exception.Message
        if ($msg -match 'Access denied') { $msg = 'Access denied - check the user name and password.' }
        elseif ($msg -match "Can't connect|2003") { $msg = "Cannot reach MySQL at $($S.MySqlHost):$($S.MySqlPort). Is the service running?" }
        $lblConn.Text = $msg
    } finally {
        $form.Cursor = 'Default'
    }
    $script:ConnOk
}

function Update-ServerPage {
    $layout = @(Get-WorldLayout)
    $parts = @('8484 (login)') + @($layout | ForEach-Object { "$($_.First)-$($_.Last) (world $($_.World), $($_.Channels) ch)" })
    $lblPorts.Text = 'TCP ' + ($parts -join ',  ')
    $bs = Get-BuildStatus
    $chkBuild.Checked = $bs.Needed
    $lblBuild.Text = $bs.Reason + $(if ($S.Jdk) { '' } else { '  (no JDK found - cannot build)' })
    $chkBuild.Enabled = [bool]$S.Jdk
    $chkLaunch.Enabled = [bool]$S.Jdk
    $chkTest.Enabled = [bool]$S.Jdk
    if ($S.Jdk) { $chkLaunch.Text = "Point launch.bat at $($S.Jdk.Bin)" }
    $chkFw.Enabled = $IsAdmin
    if (-not $IsAdmin) { $chkFw.Text = 'Allow through Windows Firewall (needs administrator - restart the wizard as admin)'; $chkFw.Checked = $false }
}

function Read-GuiState {
    $S.UseDedicated = $rbDedicated.Checked
    $S.DbUser = $tbDbUser.Text.Trim()
    $S.DbPassword = $tbDbPw.Text
    $S.ExistingDatabase = if ($rbRecreate.Checked) { 'Recreate' } else { 'Keep' }
    $S.ShopUpdate = $chkShop.Checked
    $S.RelaxSqlMode = $chkSqlMode.Checked
    $S.ServerIp = $cbIp.Text.Trim()
    $S.Firewall = $chkFw.Checked -and $chkFw.Enabled
    $S.Build = $chkBuild.Checked -and $chkBuild.Enabled
    $S.FixLaunch = $chkLaunch.Checked -and $chkLaunch.Enabled
    $S.HeapMB = [int]$numHeap.Value
    $S.DriverTest = $chkTest.Checked -and $chkTest.Enabled
}

function Get-PlanText {
    Read-GuiState
    $st = $script:DbState
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('The wizard will:')
    $lines.Add('')
    if ($st -and $st.Tables -gt 0 -and $st.Complete -and $S.ExistingDatabase -eq 'Keep') {
        $lines.Add("  - Keep the existing '$DbName' database ($($st.Accounts) accounts)")
    } else {
        if ($st -and $st.Tables -gt 0) { $lines.Add("  - Back up '$DbName' to setup\backups, then DELETE and re-create it") }
        $f = 'db_database.sql, db_drops.sql' + $(if ($S.ShopUpdate) { ', db_shopupdate.sql' } else { '' })
        $lines.Add("  - Import $f")
    }
    if ($S.RelaxSqlMode) { $lines.Add('  - Set MySQL sql_mode = NO_ENGINE_SUBSTITUTION') }
    if ($S.UseDedicated) { $lines.Add("  - Create/update MySQL account '$($S.DbUser)' with rights on '$DbName'") }
    else { $lines.Add("  - Let the server log in as '$($S.AdminUser)'") }
    $lines.Add("  - Update config.yaml: DB settings, HOST = $($S.ServerIp)  (backup kept)")
    if ($S.Build) { $lines.Add('  - Compile src\ into dist\') }
    if ($S.FixLaunch) { $lines.Add("  - Update launch.bat: JDK path, -Xmx$($S.HeapMB)m  (backup kept)") }
    if ($S.Firewall) { $lines.Add('  - Add Windows Firewall rules (group "' + $FwGroup + '")') }
    if ($S.DriverTest) { $lines.Add('  - Test the database login with the server''s JDBC driver') }
    $lines.Add('')
    $lines.Add('Click Install to start.')
    $lines -join "`r`n"
}

function Show-Page([int]$i) {
    $script:Page = $i
    for ($j = 0; $j -lt $pages.Count; $j++) {
        $pages[$j].Visible = ($j -eq $i)
        $stepLabels[$j].Font = if ($j -eq $i) { $fontBold } else { $fontUi }
        $stepLabels[$j].ForeColor = if ($j -eq $i) { [System.Drawing.Color]::White }
            elseif ($j -lt $i) { [System.Drawing.Color]::FromArgb(140, 200, 150) }
            else { [System.Drawing.Color]::FromArgb(140, 152, 175) }
    }
    $header.Text = $titles[$i][0]
    $subHeader.Text = $titles[$i][1]
    $btnBack.Enabled = ($i -gt 0)
    $btnNext.Text = if ($i -eq 3) { 'Install' } else { 'Next >' }
    if ($i -eq 2) { Update-ServerPage }
    if ($i -eq 3) { $tbLog.Text = Get-PlanText; $pbar.Value = 0 }
}

function Invoke-Next {
    switch ($script:Page) {
        0 {
            if (@(Get-MissingServerFiles).Count) {
                [void][System.Windows.Forms.MessageBox]::Show('Some server files are missing (see the list). The wizard must live in HeavenMS\setup\.', 'Requirements', 'OK', 'Error'); return
            }
            if (-not $S.MySqlExe) {
                [void][System.Windows.Forms.MessageBox]::Show('mysql.exe was not found. Install MySQL or MariaDB first.', 'Requirements', 'OK', 'Error'); return
            }
            if (-not $S.Jdk) {
                $a = [System.Windows.Forms.MessageBox]::Show('No Java 8 JDK was found, so the server cannot be built or started yet. Continue with the database setup anyway?', 'Requirements', 'YesNo', 'Warning')
                if ($a -ne 'Yes') { return }
            }
            Show-Page 1
        }
        1 {
            try { Read-DbFields } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Database', 'OK', 'Warning'); return }
            $key = "$($S.MySqlHost)|$($S.MySqlPort)|$($S.AdminUser)|$($S.AdminPassword)"
            if (-not $script:ConnOk -or $script:ConnKey -ne $key) {
                if (-not (Test-ConnectionGui)) {
                    [void][System.Windows.Forms.MessageBox]::Show("Could not connect to MySQL:`r`n$($lblConn.Text)", 'Database', 'OK', 'Warning'); return
                }
            }
            if ($rbDedicated.Checked) {
                if ($tbDbUser.Text.Trim() -notmatch '^[A-Za-z0-9_]{1,32}$') {
                    [void][System.Windows.Forms.MessageBox]::Show('The server account name may only contain letters, digits and _ (max 32).', 'Database', 'OK', 'Warning'); return
                }
                if ($tbDbUser.Text.Trim() -eq $S.AdminUser) {
                    [void][System.Windows.Forms.MessageBox]::Show('Pick a name different from the admin account, or choose "Use the admin account above".', 'Database', 'OK', 'Warning'); return
                }
                if ($tbDbPw.Text.Length -lt 8) {
                    [void][System.Windows.Forms.MessageBox]::Show('Use a password of at least 8 characters for the server account.', 'Database', 'OK', 'Warning'); return
                }
            }
            if ($rbRecreate.Checked -and $rbRecreate.Enabled -and $script:DbState.Accounts -gt 0) {
                $a = [System.Windows.Forms.MessageBox]::Show(
                    "The current database has $($script:DbState.Accounts) accounts and $($script:DbState.Characters) characters.`r`n`r`nThey will be backed up to setup\backups and then DELETED. Continue?",
                    'Re-create database', 'YesNo', 'Warning')
                if ($a -ne 'Yes') { return }
            }
            Show-Page 2
        }
        2 {
            if (-not (Test-IPv4 $cbIp.Text.Trim())) {
                [void][System.Windows.Forms.MessageBox]::Show('HOST must be an IPv4 address such as 127.0.0.1 or 203.0.113.10.', 'Server', 'OK', 'Warning'); return
            }
            Show-Page 3
        }
        3 {
            if ($script:Done) { $form.Close(); return }
            Read-GuiState
            $script:Running = $true
            $btnBack.Enabled = $false; $btnNext.Enabled = $false; $btnCancel.Enabled = $false
            $tbLog.Clear()
            $script:LogBox = $tbLog
            $script:Progress = $pbar
            $ok = $false
            try { $ok = Invoke-Setup } finally {
                $script:Running = $false
                $script:Done = $true
                $btnNext.Text = 'Finish'; $btnNext.Enabled = $true
                $btnCancel.Visible = $false
                $btnConfig.Visible = $true
                $btnLaunch.Visible = $ok -and [bool]$S.Jdk
                $subHeader.Text = if ($ok) { 'Done - the server is ready to start' } else { 'Setup stopped - see the log above' }
                $subHeader.ForeColor = if ($ok) { $cOk } else { $cBad }
            }
        }
    }
}

$btnRecheck.Add_Click({ $form.Cursor = 'WaitCursor'; try { Update-Checks } finally { $form.Cursor = 'Default' } })
$btnInstall.Add_Click({ Install-Missing })
$btnTest.Add_Click({ [void](Test-ConnectionGui) })
$btnGen.Add_Click({ $tbDbPw.Text = New-RandomPassword })
$rbDedicated.Add_CheckedChanged({ $tbDbUser.Enabled = $rbDedicated.Checked; $tbDbPw.Enabled = $rbDedicated.Checked; $btnGen.Enabled = $rbDedicated.Checked })
$btnPublic.Add_Click({
    $form.Cursor = 'WaitCursor'
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).ToString().Trim()
        if (Test-IPv4 $ip) { if (-not $cbIp.Items.Contains($ip)) { [void]$cbIp.Items.Add($ip) }; $cbIp.Text = $ip }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('Could not detect the public IP. Type it in manually.', 'Public IP', 'OK', 'Warning')
    } finally { $form.Cursor = 'Default' }
})
$btnBack.Add_Click({ if ($script:Page -gt 0 -and -not $script:Running) { Show-Page ($script:Page - 1) } })
$btnNext.Add_Click({ Invoke-Next })
$btnCancel.Add_Click({ $form.Close() })
$btnConfig.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" })
$btnLaunch.Add_Click({ Start-Process -FilePath 'cmd.exe' -ArgumentList "/k `"$LaunchBat`"" -WorkingDirectory $Root })
$form.Add_FormClosing({ param($s, $e) if ($script:Running) { $e.Cancel = $true } })
$form.Add_Shown({
    $form.Activate()
    $form.Cursor = 'WaitCursor'
    try { Update-Checks } finally { $form.Cursor = 'Default' }
})

Show-Page 0
[void]$form.ShowDialog()
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
