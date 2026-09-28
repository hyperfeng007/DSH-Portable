# Start-DSH.ps1 - DSH-Portable orchestrator (written by DeepseekHarness.exe on every launch)
#   default      : hidden launch  (progress.txt / ready.flag / error.txt talk to the exe)
#   -InstallOnly : console mode, prepare runtime only
#   -Update      : console mode, upgrade dsh to the latest version
#   -ExportEnv   : print NAME=VALUE lines (proxy etc.) for DSH-Terminal.bat
#   -Stop        : stop a running session (browser window + dsh + node) and clean up
param(
    [switch]$InstallOnly,
    [switch]$Update,
    [switch]$ExportEnv,
    [switch]$Stop
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$root     = $PSScriptRoot
$console  = [bool]($InstallOnly -or $Update -or $ExportEnv -or $Stop)
$log      = Join-Path $root 'Start-DSH.log'
$prog     = Join-Path $root 'progress.txt'
$ready    = Join-Path $root 'ready.flag'
$errf     = Join-Path $root 'error.txt'
$lock     = Join-Path $root 'run.lock'
$nodeVer  = 'v22.23.2'
$nodeZip  = Join-Path $root ('node-' + $nodeVer + '-win-x64.zip')
$nodeDir  = Join-Path $root 'node'
$nodeExe  = Join-Path $nodeDir 'node.exe'
$npmCmd   = Join-Path $nodeDir 'npm.cmd'
$dshDir   = Join-Path $root 'dsh'
$dshCmd   = Join-Path $dshDir 'dsh.cmd'
$dshPkg   = Join-Path $dshDir 'node_modules\@deepseek-ai\dsh'
$dataDir  = Join-Path $root 'dsh-home'
$workDir  = Join-Path $root 'workspace'
$tempDir  = Join-Path $root 'temp'
$profDir  = Join-Path $root 'browser-profile'
$webLog   = Join-Path $root 'dsh-web.log'
$npmLog   = Join-Path $root 'npm-install.log'
$script:dshp = $null
$script:bp   = $null
$script:win32 = $null

# ---------------------------------------------------------------- helpers
function Log([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $m
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
    if ($console -and -not $ExportEnv) { Write-Host $line }
}
function Step([int]$n) {
    if ($console) { return }
    try { [IO.File]::WriteAllText($prog, [string]$n) } catch { }
}
function Write-Utf8([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Stop-Tree([int]$id) {
    if ($id -le 0) { return }
    try { & taskkill.exe /PID $id /T /F 2>&1 | Out-Null } catch { }
}
function Stop-OurNode {
    # leftover "dsh web" servers that run from THIS folder's node.exe
    # (a dsh session someone runs by hand in DSH-Terminal.bat is left alone)
    $prefix = ($root.TrimEnd('\') + '\').ToLower()
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
        foreach ($w in $procs) {
            $exe = [string]$w.ExecutablePath
            $cl = [string]$w.CommandLine
            if ($exe -and $exe.ToLower().StartsWith($prefix) -and $cl -match '\bweb\b' -and $cl -match 'dsh') {
                Log ('  killing leftover dsh web pid=' + $w.ProcessId)
                Stop-Tree ([int]$w.ProcessId)
            }
        }
    } catch {
        Get-Process -Name node -ErrorAction SilentlyContinue | ForEach-Object {
            $p = ''
            try { $p = [string]$_.Path } catch { }
            if ($p -and $p.ToLower().StartsWith($prefix)) { Log ('  killing leftover node pid=' + $_.Id); Stop-Tree $_.Id }
        }
    }
}
function Get-AppWindowCount {
    # visible top-level windows whose title contains "DeepSeek Harness" (any process)
    if ($null -eq $script:win32) {
        $script:win32 = $false
        try {
            $script:win32 = Add-Type -Namespace DSHLauncher -Name Win -PassThru -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
public static int CountTitled(string needle) {
    int c = 0;
    EnumWindows(delegate(IntPtr h, IntPtr lp) {
        if (!IsWindowVisible(h)) return true;
        var sb = new System.Text.StringBuilder(512);
        GetWindowText(h, sb, 512);
        if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) c++;
        return true;
    }, IntPtr.Zero);
    return c;
}
'@
        } catch { Log ('  Add-Type failed, using MainWindowTitle scan: ' + $_.Exception.Message); $script:win32 = $false }
    }
    if ($script:win32 -ne $false) {
        try { return [int]$script:win32::CountTitled('DeepSeek Harness') } catch { }
    }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*DeepSeek Harness*' }).Count
}
function Send-CtrlC([int]$id) {
    # real Ctrl+C on the target's hidden console -> dsh runs its SIGINT shutdown
    $helper = Join-Path $root 'ctrlc.exe'
    if ($id -le 0 -or -not (Test-Path -LiteralPath $helper)) { return $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $helper
        $psi.Arguments = [string]$id
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $h = [System.Diagnostics.Process]::Start($psi)
        if (-not $h.WaitForExit(3000)) { try { $h.Kill() } catch { }; return $false }
        if ($h.ExitCode -ne 0) { Log ('  ctrlc helper exit=' + $h.ExitCode); return $false }
        return $true
    } catch { Log ('  ctrlc failed: ' + $_.Exception.Message); return $false }
}
function Stop-Dsh {
    if (-not $script:dshp) { return }
    try { $script:dshp.Refresh() } catch { }
    if (-not $script:dshp.HasExited) {
        if (Send-CtrlC $script:dshp.Id) {
            if ($script:dshp.WaitForExit(5000)) { Log "  dsh exited gracefully (Ctrl+C)" }
            else { Log "  dsh ignored Ctrl+C for 5 s - force killing" }
        }
    }
    try { $script:dshp.Refresh() } catch { }
    if (-not $script:dshp.HasExited) { Stop-Tree $script:dshp.Id }
}
function Cleanup {
    Log 'cleanup: stopping everything we started'
    Stop-Dsh
    Stop-OurNode
    if ($script:bp) {
        try { $script:bp.Refresh(); if (-not $script:bp.HasExited) { Stop-Tree $script:bp.Id } } catch { }
    }
    foreach ($f in @($lock, $prog)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
function Fail([string]$msg) {
    Log ('FAIL: ' + $msg)
    try { Write-Utf8 $errf $msg } catch { }
    Cleanup
    Log '== aborted =='
    exit 1
}
function Tail-Log([string]$path, [int]$n) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return '' }
        $lines = Get-Content -LiteralPath $path -Tail $n -ErrorAction SilentlyContinue
        $txt = ($lines -join "`n") -replace ([string][char]27 + '\[[0-9;]*[A-Za-z]'), ''
        return $txt
    } catch { return '' }
}
function Invoke-Hidden([string]$file, [string]$argLine, [string]$workdir, [string]$outFile) {
    # NOTE: never name a parameter $args - PowerShell overwrites it with the automatic variable
    # console mode: children inherit our console (user sees live output)
    # hidden mode : no window at all, stdout+stderr go to $outFile
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    if ($console -or -not $outFile) {
        $psi.Arguments = '/d /s /c ""' + $file + '" ' + $argLine + '"'
    } else {
        $psi.Arguments = '/d /s /c ""' + $file + '" ' + $argLine + ' > "' + $outFile + '" 2>&1"'
    }
    $psi.WorkingDirectory = $workdir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = (-not $console)
    Log ('  run: ' + $file + ' ' + $argLine)
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return $p.ExitCode
}

# ---------------------------------------------------------------- proxy import
function Normalize-ProxyUrl([string]$v) {
    if (-not $v) { return '' }
    $v = $v.Trim().Trim('"').Trim("'")
    if ($v -eq '') { return '' }
    if ($v -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $v = 'http://' + $v }
    if ($v -match '^socks') { return '' }      # dsh only routes http(s):// proxies
    return $v.TrimEnd('/')
}
function Parse-ProxyList([string]$ps, [hashtable]$r) {
    # WinINET / WinHTTP syntax:  "host:port"  or  "http=h:p;https=h:p;ftp=...;socks=..."
    if ($ps -match '=') {
        foreach ($part in ($ps -split ';')) {
            $kv = $part -split '=', 2
            if ($kv.Count -ne 2) { continue }
            switch ($kv[0].Trim().ToLower()) {
                'http'  { $r.http  = Normalize-ProxyUrl $kv[1] }
                'https' { $r.https = Normalize-ProxyUrl $kv[1] }
            }
        }
    } else {
        $r.http = Normalize-ProxyUrl $ps
        $r.https = $r.http
    }
    if (-not $r.https -and $r.http) { $r.https = $r.http }
    if (-not $r.http -and $r.https) { $r.http = $r.https }
}
function Convert-Bypass([string]$ov) {
    if (-not $ov) { return '' }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($e in ($ov -split '[;,\s]+')) {
        $e = $e.Trim()
        if ($e -eq '') { continue }
        if ($e -eq '<local>') {
            foreach ($x in @('localhost', '127.0.0.1', '::1')) { if (-not $out.Contains($x)) { $out.Add($x) } }
            continue
        }
        if ($e -match '/') { continue }          # CIDR is not matchable by dsh/Node
        if (-not $out.Contains($e)) { $out.Add($e) }
    }
    return ($out -join ',')
}
function Mask([string]$u) { return ($u -replace '(://)[^/@]+@', '$1***@') }

function Resolve-SystemProxy {
    $r = @{ http = ''; https = ''; noproxy = ''; source = 'none' }
    $reg = $null
    try { $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { }

    # 1) Internet Options -> manual proxy (also what Clash/V2Ray "system proxy" switches set)
    if ($reg -and $reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
        Parse-ProxyList ([string]$reg.ProxyServer) $r
        if ($r.http -or $r.https) {
            $r.noproxy = Convert-Bypass ([string]$reg.ProxyOverride)
            $r.source = 'Internet Options (manual proxy)'
            return $r
        }
    }
    # 2) PAC script / WPAD auto-detect -> let the OS engine resolve a concrete proxy for our real targets
    $pacUrl = ''
    if ($reg) { $pacUrl = [string]$reg.AutoConfigURL }
    $autoDetect = $false
    try {
        $conn = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -ErrorAction Stop
        $ds = $conn.DefaultConnectionSettings
        if ($ds -and $ds.Length -ge 12) { $autoDetect = (([BitConverter]::ToInt32($ds, 8) -band 8) -ne 0) }
    } catch { }
    if ($pacUrl -or $autoDetect) {
        try {
            $sp = [System.Net.WebRequest]::GetSystemWebProxy()
            foreach ($t in @('https://api.deepseek.com/', 'https://registry.npmjs.org/', 'https://www.baidu.com/')) {
                $u = [Uri]$t
                $p = $sp.GetProxy($u)
                if ($p -and $p.AbsoluteUri -ne $u.AbsoluteUri) {
                    $r.https = Normalize-ProxyUrl $p.AbsoluteUri
                    $r.http = $r.https
                    break
                }
            }
        } catch { Log ('  pac resolve failed: ' + $_.Exception.Message) }
        if ($r.https) {
            if ($reg) { $r.noproxy = Convert-Bypass ([string]$reg.ProxyOverride) }
            if ($pacUrl) { $r.source = 'PAC script (' + $pacUrl + ')' } else { $r.source = 'proxy auto-detect (WPAD)' }
            return $r
        }
    }
    # 3) HTTP_PROXY / HTTPS_PROXY / ALL_PROXY already exported by the user or the system
    $eh = $env:HTTP_PROXY; $es = $env:HTTPS_PROXY; $ea = $env:ALL_PROXY
    if ($eh -or $es -or $ea) {
        $h = $eh; if (-not $h) { $h = $ea }
        $s = $es; if (-not $s) { $s = $ea }; if (-not $s) { $s = $eh }
        $r.http = Normalize-ProxyUrl $h
        $r.https = Normalize-ProxyUrl $s
        if ($r.http -or $r.https) {
            $r.noproxy = Convert-Bypass ([string]$env:NO_PROXY)
            $r.source = 'environment variables'
            return $r
        }
    }
    # 4) machine-wide WinHTTP proxy (netsh winhttp set proxy)
    try {
        $b = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -ErrorAction Stop).WinHttpSettings
        if ($b -and $b.Length -ge 16) {
            $flags = [BitConverter]::ToInt32($b, 8)
            $len = [BitConverter]::ToInt32($b, 12)
            if ($len -gt 0 -and ($flags -band 2) -ne 0 -and (16 + $len) -le $b.Length) {
                $pstr = [Text.Encoding]::ASCII.GetString($b, 16, $len)
                $bstr = ''
                if ((20 + $len) -le $b.Length) {
                    $bl = [BitConverter]::ToInt32($b, 16 + $len)
                    if ($bl -gt 0 -and (20 + $len + $bl) -le $b.Length) { $bstr = [Text.Encoding]::ASCII.GetString($b, 20 + $len, $bl) }
                }
                Parse-ProxyList $pstr $r
                if ($r.http -or $r.https) {
                    $r.noproxy = Convert-Bypass $bstr
                    $r.source = 'WinHTTP (netsh winhttp)'
                    return $r
                }
            }
        }
    } catch { }
    return $r
}

function Import-Proxy {
    # Node/npm/dsh never look at the Windows proxy settings, so we translate them into env vars.
    # Node 22.19+ : NODE_USE_SYSTEM_CA=1 makes Node trust the Windows certificate store as well
    #               (needed behind TLS-inspecting corporate proxies).
    $env:NODE_USE_SYSTEM_CA = '1'
    $skipFile = Join-Path $dataDir 'no-proxy-import.txt'
    if (Test-Path -LiteralPath $skipFile) { Log 'proxy: auto import disabled (dsh-home\no-proxy-import.txt)'; return }
    $envFile = Join-Path $dataDir '.env'
    if (Test-Path -LiteralPath $envFile) {
        $manual = Select-String -LiteralPath $envFile -Pattern '^\s*(https?_proxy|all_proxy)\s*=' -Quiet
        if ($manual) { Log 'proxy: manual settings found in dsh-home\.env, auto import skipped'; return }
    }
    $p = Resolve-SystemProxy
    if (-not ($p.http -or $p.https)) { Log 'proxy: none detected -> direct connection'; return }
    if ($p.http)  { $env:HTTP_PROXY  = $p.http;  $env:NPM_CONFIG_PROXY = $p.http }
    if ($p.https) { $env:HTTPS_PROXY = $p.https; $env:NPM_CONFIG_HTTPS_PROXY = $p.https }
    if ($p.noproxy) { $env:NO_PROXY = $p.noproxy; $env:NPM_CONFIG_NOPROXY = $p.noproxy }
    if ($p.source -ne 'environment variables' -and $env:ALL_PROXY) { Remove-Item Env:ALL_PROXY -ErrorAction SilentlyContinue }
    Log ('proxy: ' + $p.source + '  HTTP=' + (Mask $p.http) + '  HTTPS=' + (Mask $p.https) + '  NO_PROXY=' + $p.noproxy)
}

# ---------------------------------------------------------------- environment
function Set-PortableEnv {
    $env:PATH = $nodeDir + ';' + $dshDir + ';' + $env:PATH
    $env:NPM_CONFIG_PREFIX = $dshDir
    $env:NPM_CONFIG_CACHE = Join-Path $root 'npm-cache'
    $env:NPM_CONFIG_UPDATE_NOTIFIER = 'false'
    $env:NPM_CONFIG_FUND = 'false'
    $env:NPM_CONFIG_AUDIT = 'false'
    $env:NODE_REPL_HISTORY = Join-Path $root 'node_repl_history.txt'
    $env:DSH_HOME = $dataDir
    $env:DSH_TELEMETRY_DISABLED = '1'
    $env:DSH_TELEMETRY_MODE = 'DISABLED'
    $env:TMP = $tempDir
    $env:TEMP = $tempDir
    foreach ($d in @($dataDir, $workDir, $tempDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# ---------------------------------------------------------------- install / update
function Install-Runtime {
    if (-not (Test-Path -LiteralPath $nodeExe)) {
        Step 4
        Log 'node runtime missing - preparing'
        if (-not (Test-Path -LiteralPath $nodeZip)) {
            Log 'node zip not found - downloading'
            $urls = @(
                ('https://npmmirror.com/mirrors/node/' + $nodeVer + '/node-' + $nodeVer + '-win-x64.zip'),
                ('https://nodejs.org/dist/' + $nodeVer + '/node-' + $nodeVer + '-win-x64.zip')
            )
            foreach ($u in $urls) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $u -OutFile $nodeZip -UseBasicParsing -TimeoutSec 900
                    if ((Get-Item -LiteralPath $nodeZip).Length -gt 10MB) { Log ('  downloaded from ' + $u); break }
                } catch { Log ('  download failed: ' + $u + ' -> ' + $_.Exception.Message) }
            }
            if (-not (Test-Path -LiteralPath $nodeZip) -or (Get-Item -LiteralPath $nodeZip).Length -lt 10MB) {
                Remove-Item -LiteralPath $nodeZip -Force -ErrorAction SilentlyContinue
                Fail ('无法下载 Node.js 运行时（需要联网）。' + "`n" + '请手动下载 ' + $urls[1] + "`n" + '放到本文件夹后再双击一次。')
            }
        }
        $tmp = Join-Path $root 'node.tmp'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($nodeZip, $tmp)
        } catch {
            Log ('  zip extract failed: ' + $_.Exception.Message)
            Fail ('解压 Node.js 运行时失败：' + $_.Exception.Message + "`n" + '请确认本文件夹可写、磁盘空间足够（需约 300 MB），并尽量放在较短的路径下（如 D:\DSH）。')
        }
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $inner) { Fail ('Node.js 压缩包内容异常，请重新下载 node-' + $nodeVer + '-win-x64.zip。') }
        if (Test-Path -LiteralPath $nodeDir) { Remove-Item -LiteralPath $nodeDir -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $inner.FullName -Destination $nodeDir
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $nodeExe)) { Fail 'Node.js 运行时解压后不完整（node\node.exe 不存在）。' }
        Log 'node ready'
    }
    if ($Update -or -not (Test-Path -LiteralPath $dshCmd)) {
        Step 5
        Log 'installing @deepseek-ai/dsh (npm install -g) ...'
        if (Test-Path -LiteralPath $npmLog) { Remove-Item -LiteralPath $npmLog -Force -ErrorAction SilentlyContinue }
        $rc = Invoke-Hidden $npmCmd 'install -g @deepseek-ai/dsh@latest' $root $npmLog
        if ($rc -ne 0) {
            Log ('  npm exit=' + $rc + ' - retrying with registry.npmmirror.com')
            $rc = Invoke-Hidden $npmCmd 'install -g @deepseek-ai/dsh@latest --registry=https://registry.npmmirror.com' $root $npmLog
        }
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $dshCmd)) {
            $tail = Tail-Log $npmLog 12
            Fail ('安装 DeepSeek Harness 失败（npm 退出码 ' + $rc + '），通常是网络或代理问题。' + "`n`n" + $tail)
        }
        $ver = ''
        try { $pj = Get-Content -LiteralPath (Join-Path $dshPkg 'package.json') -Raw | ConvertFrom-Json; $ver = [string]$pj.version } catch { }
        Log ('dsh ready, version ' + $ver)
    }
}

# ---------------------------------------------------------------- launch
function Get-DshEntry {
    try {
        $pj = Get-Content -LiteralPath (Join-Path $dshPkg 'package.json') -Raw | ConvertFrom-Json
        $bin = $pj.bin
        $rel = $null
        if ($bin -is [string]) { $rel = $bin } elseif ($bin -and $bin.dsh) { $rel = $bin.dsh }
        if ($rel) {
            $full = Join-Path $dshPkg $rel
            if (Test-Path -LiteralPath $full) { return $full }
        }
    } catch { }
    return $null
}
function Get-PortOwner([int]$port) {
    # >0 owner pid, 0 free, -1 busy but unknown owner
    try {
        $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
        return 0
    } catch { }
    try {
        $t = New-Object Net.Sockets.TcpClient
        $t.Connect('127.0.0.1', $port); $t.Close()
        return -1
    } catch { return 0 }
}
function Test-Port([int]$port) {
    try { $t = New-Object Net.Sockets.TcpClient; $t.Connect('127.0.0.1', $port); $t.Close(); return $true } catch { return $false }
}
function Find-Browser {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($exe in @('msedge.exe', 'chrome.exe')) {
        foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\')) {
            try {
                $v = (Get-ItemProperty -LiteralPath ($hive + $exe) -ErrorAction Stop).'(default)'
                if ($v) { $cands.Add(([string]$v).Trim('"')) }
            } catch { }
        }
    }
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}; $la = $env:LOCALAPPDATA
    foreach ($c in @(
        "$pf\Microsoft\Edge\Application\msedge.exe", "$pf86\Microsoft\Edge\Application\msedge.exe", "$la\Microsoft\Edge\Application\msedge.exe",
        "$pf\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$la\Google\Chrome\Application\chrome.exe")) { $cands.Add($c) }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}
function Test-HasWindow($proc) {
    try { $proc.Refresh(); return ($proc.MainWindowHandle.ToInt64() -ne 0) } catch { return $false }
}
function Find-OurBrowser {
    # after a hand-off / self-relaunch: the browser process that owns OUR profile folder
    try {
        $all = Get-CimInstance -ClassName Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction Stop
        foreach ($w in $all) {
            $cl = [string]$w.CommandLine
            if ($cl -and $cl.ToLower().Contains($profDir.ToLower()) -and $cl -notmatch '--type=') {
                return (Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue)
            }
        }
    } catch { }
    return $null
}
function Write-Lock {
    $bpid = 0; $dpid = 0
    if ($script:bp) { try { $bpid = $script:bp.Id } catch { } }
    if ($script:dshp) { try { $dpid = $script:dshp.Id } catch { } }
    try { [IO.File]::WriteAllText($lock, ('pid=' + $PID + "`r`n" + 'dsh=' + $dpid + "`r`n" + 'browser=' + $bpid + "`r`n")) } catch { }
}

# ================================================================= main
if ($ExportEnv) {
    Set-PortableEnv
    Import-Proxy
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'NPM_CONFIG_PROXY', 'NPM_CONFIG_HTTPS_PROXY', 'NPM_CONFIG_NOPROXY', 'NODE_USE_SYSTEM_CA')) {
        $v = [Environment]::GetEnvironmentVariable($n, 'Process')
        if ($v) { Write-Output ($n + '=' + $v) }
    }
    exit 0
}

if ($Stop) {
    Log '== stop requested =='
    if (Test-Path -LiteralPath $lock) {
        $txt = ''
        try { $txt = Get-Content -LiteralPath $lock -Raw } catch { }
        $ids = @{}
        foreach ($k in @('pid', 'browser', 'dsh')) {
            $m = [regex]::Match($txt, $k + '=(\d+)')
            if ($m.Success -and [int]$m.Groups[1].Value -gt 0 -and [int]$m.Groups[1].Value -ne $PID) { $ids[$k] = [int]$m.Groups[1].Value }
        }
        if ($ids['pid']) { Log ('  stopping launcher ' + $ids['pid']); Stop-Tree $ids['pid'] }   # no more monitoring/popups
        if ($ids['dsh']) {
            $dp = Get-Process -Id $ids['dsh'] -ErrorAction SilentlyContinue
            if ($dp -and (Send-CtrlC $ids["dsh"])) { if ($dp.WaitForExit(5000)) { Log '  dsh exited gracefully (Ctrl+C)' } }
            Stop-Tree $ids['dsh']
        }
        if ($ids['browser']) { Log ('  stopping browser ' + $ids['browser']); Stop-Tree $ids['browser'] }
    }
    Stop-OurNode
    foreach ($f in @($lock, $prog, $ready, $errf)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Log 'stopped.'
    exit 0
}

try { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue } catch { }
foreach ($f in @($prog, $ready, $errf)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
Log ('== start ==  mode=' + $(if ($InstallOnly) { 'install' } elseif ($Update) { 'update' } else { 'launch' }) + '  root=' + $root)
Step 1
Set-PortableEnv

Step 2
Import-Proxy

Step 3
# previous run left something behind? (crash, USB pulled, ...)
if (Test-Path -LiteralPath $lock) {
    $old = 0
    try { $m = [regex]::Match((Get-Content -LiteralPath $lock -Raw), 'pid=(\d+)'); if ($m.Success) { $old = [int]$m.Groups[1].Value } } catch { }
    if ($old -gt 0 -and $old -ne $PID) {
        $op = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($op -and $op.ProcessName -match 'powershell') { Log ('previous launcher pid=' + $old + ' still alive - stopping it'); Stop-Tree $old }
    }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
Stop-OurNode
if (-not $console) { Write-Lock }

Install-Runtime
if ($InstallOnly -or $Update) {
    $v = ''
    try { $pj = Get-Content -LiteralPath (Join-Path $dshPkg 'package.json') -Raw | ConvertFrom-Json; $v = [string]$pj.version } catch { }
    Log ('done. dsh ' + $v + ' is ready - just double-click DeepseekHarness.exe')
    Log '== done =='
    exit 0
}

# ---- start the dsh web server (hidden)
Step 6
if (Test-Path -LiteralPath $webLog) { Remove-Item -LiteralPath $webLog -Force -ErrorAction SilentlyContinue }
$entry = Get-DshEntry
if ($entry) { $inner = '"' + $nodeExe + '" "' + $entry + '"' } else { $inner = '"' + $dshCmd + '"' }
$portArgs = ''
$owner = Get-PortOwner 3080
if ($owner -ne 0) {
    $ours = $false
    if ($owner -gt 0) {
        $op = Get-Process -Id $owner -ErrorAction SilentlyContinue
        $opPath = ''
        if ($op) { try { $opPath = [string]$op.Path } catch { } }
        if ($opPath -and $opPath.ToLower().StartsWith(($root.TrimEnd('\') + '\').ToLower())) { $ours = $true }
    }
    if ($ours) { Log ('port 3080 held by our old process pid=' + $owner + ' - killing'); Stop-Tree $owner; Start-Sleep -Milliseconds 800 }
    else { Log ('port 3080 busy (pid=' + $owner + ', not ours) - letting the OS pick a free port'); $portArgs = ' --port 0' }
}
$cmdArgs = '/d /s /c "' + $inner + ' web --no-open' + $portArgs + ' > "' + $webLog + '" 2>&1"'
Log ('launching dsh web (hidden): ' + $inner + ' web --no-open' + $portArgs)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
$psi.Arguments = $cmdArgs
$psi.WorkingDirectory = $workDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
try { $script:dshp = [System.Diagnostics.Process]::Start($psi) } catch { Fail ('无法启动 dsh：' + $_.Exception.Message) }
Log ('dsh pid=' + $script:dshp.Id)
Write-Lock

# ---- wait for the authenticated URL
Step 7
$url = $null
$deadline = (Get-Date).AddSeconds(150)
$rx = [regex]'https?://(127\.0\.0\.1|localhost|\[::1\]):\d+[^\s"''<>()\[\]`]*token=[^\s"''<>()\[\]`]+'
while ((Get-Date) -lt $deadline) {
    if ($script:dshp.HasExited) { break }
    if (Test-Path -LiteralPath $webLog) {
        $raw = Get-Content -LiteralPath $webLog -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $clean = $raw -replace ([string][char]27 + '\[[0-9;]*[A-Za-z]'), ''
            $m = $rx.Match($clean)
            if ($m.Success) { $url = $m.Value; break }
        }
    }
    Start-Sleep -Milliseconds 300
}
if (-not $url) {
    $tail = Tail-Log $webLog 15
    if ($script:dshp.HasExited) { Fail ('DeepSeek Harness 服务启动后立即退出（退出码 ' + $script:dshp.ExitCode + '）。' + "`n`n" + $tail) }
    Fail ('DeepSeek Harness 服务启动超时（150 秒内未就绪）。' + "`n`n" + $tail)
}
$port = 3080
$pm = [regex]::Match($url, ':(\d+)')
if ($pm.Success) { $port = [int]$pm.Groups[1].Value }
for ($i = 0; $i -lt 40; $i++) { if (Test-Port $port) { break }; Start-Sleep -Milliseconds 250 }
Log ('dsh ready on port ' + $port)

# ---- open the app window (own browser profile inside this folder -> trackable + zero residue)
Step 8
$browser = Find-Browser
if (-not (Test-Path -LiteralPath $profDir)) { New-Item -ItemType Directory -Path $profDir -Force | Out-Null }
$tracked = $false
if ($browser) {
    $bargs = @(
        ('--app=' + $url),
        ('--user-data-dir="' + $profDir + '"'),
        '--no-first-run', '--no-default-browser-check', '--disable-background-mode', '--disable-sync',
        '--no-service-autorun', '--disable-session-crashed-bubble', '--hide-crash-restore-bubble',
        '--disk-cache-size=33554432', '--window-size=1280,820', '--window-position=80,60'
    )
    try {
        $script:bp = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru
        $tracked = $true
        Log ('browser: ' + $browser + '  pid=' + $script:bp.Id)
    } catch { Log ('browser launch failed: ' + $_.Exception.Message) }
}
if (-not $tracked) {
    Log 'no Edge/Chrome found - opening the default browser (window cannot be tracked)'
    Start-Process $url
}
Write-Lock

# wait until the window is really on screen, then let the progress bar go away
$seen = $false
$launchAt = Get-Date
$wdead = $launchAt.AddSeconds(20)
$closedEarly = $false
while ((Get-Date) -lt $wdead) {
    Start-Sleep -Milliseconds 250
    if (-not $tracked) { break }
    try { $script:bp.Refresh() } catch { }
    if ($script:bp.HasExited) {
        $nb = Find-OurBrowser
        if ($nb) { Log ('browser handed off to pid=' + $nb.Id); $script:bp = $nb; Write-Lock; continue }
        if ($seen -or ((Get-Date) - $launchAt).TotalSeconds -gt 3) { Log 'window closed during startup'; $closedEarly = $true; break }
        Log 'browser process exited right away (hand-off to an existing instance?)'; $tracked = $false; break
    }
    if (Test-HasWindow $script:bp) { $seen = $true; break }
}
if ($closedEarly) {
    try { [IO.File]::WriteAllText($ready, '1') } catch { }
    Cleanup
    Log '== done (closed during startup) =='
    exit 0
}
Log ('window visible=' + $seen + ' -> ready')
try { [IO.File]::WriteAllText($ready, '1') } catch { }
Remove-Item -LiteralPath $prog -Force -ErrorAction SilentlyContinue

# ---- monitor: app window closed  ->  stop dsh + node + anything else we started
$noWinSince = $null
$reason = ''
while ($true) {
    Start-Sleep -Seconds 1
    if ($script:dshp.HasExited) { $reason = 'dsh exited'; break }
    if ($tracked) {
        try { $script:bp.Refresh() } catch { }
        if ($script:bp.HasExited) {
            $nb = Find-OurBrowser
            if ($nb) { Log ('browser relaunched itself as pid=' + $nb.Id); $script:bp = $nb; Write-Lock; continue }
            $reason = 'window closed'; break
        }
        if (Test-HasWindow $script:bp) { $seen = $true; $noWinSince = $null }
        elseif ($seen) {
            if (-not $noWinSince) { $noWinSince = Get-Date }
            elseif (((Get-Date) - $noWinSince).TotalSeconds -ge 8) { $reason = 'window gone (browser lingering in background)'; break }
        }
    } else {
        # untracked (hand-off / default browser): scan window titles instead
        if ((Get-AppWindowCount) -gt 0) { $seen = $true; $noWinSince = $null }
        elseif (-not $seen -and ((Get-Date) - $launchAt).TotalSeconds -gt 90) { $reason = 'no app window appeared within 90 s'; break }
        elseif ($seen) {
            if (-not $noWinSince) { $noWinSince = Get-Date }
            elseif (((Get-Date) - $noWinSince).TotalSeconds -ge 5) { $reason = 'window closed (title scan)'; break }
        }
    }
}
Log ('stopping: ' + $reason)
if ($reason -eq 'dsh exited') {
    Cleanup
    try { (New-Object -ComObject WScript.Shell).Popup('DeepSeek Harness 服务已停止，窗口已关闭。' + "`n" + '详情见同目录 dsh-web.log。', 15, 'DeepSeek Harness', 48) | Out-Null } catch { }
} else {
    Cleanup
}
Log '== done =='
exit 0
