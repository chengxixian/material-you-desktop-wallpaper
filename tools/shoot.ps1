# 产出「真实运行截图」：写配置 → 启动 EXE → 等首帧 → 抓窗口位图。
#
# 本机执行策略是 Restricted，.ps1 不能直接运行，用 ScriptBlock 载入：
#   $sb = [ScriptBlock]::Create([IO.File]::ReadAllText("tools\shoot.ps1")); & $sb
#
# 所有截图都是真实 EXE 在真实窗口里渲染后抓的，不做设计稿、不 P 图。
# 默认抓的是 **dist 里的成品 exe**（用户拿到手的那个），不是 build 中间产物。
param(
    [string]$Exe = "",
    [string]$OutDir = "",
    [string]$CaptureScript = ""
)

$ErrorActionPreference = "Stop"
# 用 ScriptBlock 方式载入时 $PSCommandPath 为空，此时以当前目录为工程根。
$root = if ($PSCommandPath) { Split-Path -Parent (Split-Path -Parent $PSCommandPath) } else { (Get-Location).Path }
if (-not $Exe) {
    $distExe = Join-Path $root "dist\material_desktop.exe"
    $Exe = if (Test-Path -LiteralPath $distExe) { $distExe } else { Join-Path $root "build\windows\x64\runner\Release\material_desktop.exe" }
}
if (-not $OutDir) { $OutDir = Join-Path $root "shots" }
if (-not $CaptureScript) { $CaptureScript = Join-Path $root "tools\capture-window.ps1" }

if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到 EXE：$Exe（先跑 flutter build windows --release）" }
$capture = [ScriptBlock]::Create([IO.File]::ReadAllText($CaptureScript))
[IO.Directory]::CreateDirectory($OutDir) | Out-Null

$cfgDir = Join-Path $env:LOCALAPPDATA "MaterialDesktop"
[IO.Directory]::CreateDirectory($cfgDir) | Out-Null
$cfgPath = Join-Path $cfgDir "settings.json"
$backup = $null
if (Test-Path -LiteralPath $cfgPath) { $backup = [IO.File]::ReadAllText($cfgPath) }

$base = [ordered]@{
    wallpaper       = ""
    wallpaperId     = "mesh"
    rotate          = $false
    rotateMinutes   = 30
    dark            = $true
    autoColor       = $true
    highContrast    = $false
    seedColor       = ""
    clock           = $true
    clock24h        = $true
    clockSeconds    = $false
    weather         = $true
    weatherDays     = $true
    weatherChart    = $true
    music           = $true
    source          = "cloudmusic.exe"
    city            = "桐城"
    latitude        = 35.35468
    longitude       = 111.21608
}

function New-Config([hashtable]$overrides) {
    $c = [ordered]@{}
    foreach ($k in $base.Keys) { $c[$k] = $base[$k] }
    foreach ($k in $overrides.Keys) { $c[$k] = $overrides[$k] }
    return ($c | ConvertTo-Json -Compress)
}

$shots = @(
    @{ name = "01-settings-appearance"; args = "--settings --tab=0"; cfg = @{} },
    @{ name = "02-settings-widgets";    args = "--settings --tab=1"; cfg = @{} },
    @{ name = "03-settings-player";     args = "--settings --tab=2"; cfg = @{} },
    @{ name = "04-wallpaper-mesh";      args = "--wallpaper";        cfg = @{ wallpaperId = "mesh" } },
    @{ name = "05-wallpaper-neon";      args = "--wallpaper";        cfg = @{ wallpaperId = "neon" } },
    @{ name = "06-wallpaper-ocean-light"; args = "--wallpaper";      cfg = @{ wallpaperId = "ocean"; dark = $false } },
    @{ name = "07-wallpaper-aurora-12h-seconds"; args = "--wallpaper"; cfg = @{ wallpaperId = "aurora"; clock24h = $false; clockSeconds = $true; highContrast = $true } },
    @{ name = "08-wallpaper-sunset-minimal"; args = "--wallpaper";   cfg = @{ wallpaperId = "sunset"; weather = $false; music = $false } }
)

try {
    foreach ($shot in $shots) {
        $json = New-Config $shot.cfg
        [IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        $out = Join-Path $OutDir ("$($shot.name).png")
        Write-Host "── $($shot.name)  ($($shot.args))"
        & $capture -Exe $Exe -Arguments $shot.args -Out $out -WaitSeconds 30
    }
} finally {
    if ($null -ne $backup) {
        [IO.File]::WriteAllText($cfgPath, $backup, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "已恢复原配置：$cfgPath"
    }
    # 收尾兜底：截图期间启动的实例本应由抓图脚本杀掉，但万一有残留，
    # 它会和 Wallpaper Engine 托管的壁纸**互相覆盖**（桌面看起来变成某张截图的配置）。
    # 判据：父进程不是 wallpaper64/32 的，都不是 WE 托管的那个 → 杀掉。
    Get-CimInstance Win32_Process -Filter "Name='material_desktop.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        $parent = Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue
        if (-not $parent -or $parent.ProcessName -notlike "wallpaper*") {
            Write-Host "清理残留壁纸进程 pid=$($_.ProcessId)（父进程：$(if ($parent) { $parent.ProcessName } else { '已退出' })）"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}
