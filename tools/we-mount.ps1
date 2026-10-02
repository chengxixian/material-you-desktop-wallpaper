# Wallpaper Engine「应用程序壁纸」挂载 / 还原 / 状态查询。
#
# 背景（实测得出，别再踩）：
#   * WE 2.8.42 起**从创意工坊下架**了 Application 类型壁纸（安全原因），
#     但**本机自用仍然支持** —— 本地工程照常能加载运行。
#   * Application 壁纸的 project.json 只有 {"file": "<exe>", "title": ...}，
#     WE 启动 exe 时**不会附加任何命令行参数**。所以 exe 必须做到
#     「无参数 = 壁纸模式」，否则 WE 里会弹出控制中心窗口。
#   * WE 官方命令行（需 WE 已在运行）：
#       wallpaper64.exe -control openWallpaper -file <project.json>
#       wallpaper64.exe -control getWallpaper        # 打印当前壁纸路径，可用于验收
#
# 用法（执行策略 Restricted，用 ScriptBlock 载入）：
#   $sb=[ScriptBlock]::Create([IO.File]::ReadAllText("tools\we-mount.ps1"))
#   & $sb -Action status
#   & $sb -Action mount            # 默认部署 <工程根>\dist\we-project
#   & $sb -Action restore
param(
    [ValidateSet("status", "mount", "restore", "unmount")][string]$Action = "status",
    [string]$WeDir = "D:\SteamLibrary\steamapps\common\wallpaper_engine",
    [string]$ProjectName = "material-you-desktop-wallpaper",
    [string]$ExeDir = "",
    [switch]$KeepWallpaper
)

$ErrorActionPreference = "Stop"
$we = $WeDir
$wallpaperExe = Join-Path $we "wallpaper64.exe"
if (-not (Test-Path -LiteralPath $wallpaperExe)) { throw "找不到 $wallpaperExe" }

$projectsRoot = Join-Path $we "projects\myprojects"
$projectDir = Join-Path $projectsRoot $ProjectName
$projectJson = Join-Path $projectDir "project.json"
$configPath = Join-Path $we "config.json"
# 用 ScriptBlock 方式载入时 $PSScriptRoot 为空 → 状态文件放在当前目录的 tools\ 下。
$statePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot "we-mount-state.json" } else { Join-Path (Get-Location).Path "tools\we-mount-state.json" }

function Invoke-We([string[]]$weArgs, [int]$timeoutSec = 60) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wallpaperExe
    $psi.Arguments = ($weArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        $p.Kill()
        return "(timeout)"
    }
    $out = $p.StandardOutput.ReadToEnd().Trim()
    $err = $p.StandardError.ReadToEnd().Trim()
    if ($err) { return "$out$([Environment]::NewLine)[stderr] $err" }
    return $out
}

function Get-WeProcess {
    Get-Process wallpaper64, wallpaper32, launcher -ErrorAction SilentlyContinue
}

function Ensure-We {
    if (Get-WeProcess) { return $true }
    Write-Host "启动 Wallpaper Engine ..."
    Start-Process -FilePath $wallpaperExe | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if (Get-WeProcess) {
            # 再等它把壁纸服务拉起来
            Start-Sleep -Seconds 8
            return $true
        }
    }
    return $false
}

function Get-ConfigWallpaper {
    # `-control getWallpaper` 在部分版本/上升期会打印空；config.json 里的
    # selectedwallpapers 才是权威持久化状态，用它兜底。
    # ⚠️ 必须用 [IO.File]::ReadAllText 按 UTF-8 读：Get-Content 默认按 ANSI
    # 解码，config.json 里的中文用户名键（"Admin（无密码）"）会变乱码，
    # 于是 `$c.$userKey` 取到 null。这里直接用正则从原文里抠。
    try {
        $raw = [IO.File]::ReadAllText($configPath)
        $m = [regex]::Match($raw, '"selectedwallpapers"\s*:\s*\{[\s\S]*?"Monitor0"\s*:\s*\{\s*"file"\s*:\s*"([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
        return ""
    } catch {
        return ""
    }
}

function Save-StateOnce {
    if (Test-Path -LiteralPath $statePath) { return }
    $prev = Invoke-We @("-control", "getWallpaper")
    if (-not $prev) { $prev = Get-ConfigWallpaper }
    # config.json 用**字节级复制**备份。绝不用 Get-Content 读成字符串再写回：
    # 那是 ANSI 解码，会把中文用户名键写成乱码，等于把用户的 WE 设置毁掉。
    $backupCopy = Join-Path (Split-Path -Parent $statePath) "we-config-backup.json"
    Copy-Item -LiteralPath $configPath -Destination $backupCopy -Force
    $state = [ordered]@{
        previousWallpaper     = $prev
        previousConfigBackup  = $backupCopy
        savedAt               = (Get-Date).ToString("s")
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已记录原壁纸到 $statePath ：$prev"
}

switch ($Action) {
    "status" {
        $procs = Get-WeProcess
        Write-Host "WE 进程        : $(if ($procs) { ($procs | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', ' } else { '未运行' })"
        Write-Host "WE 目录        : $we"
        Write-Host "工程目录       : $projectDir $(if (Test-Path $projectDir) { '(存在)' } else { '(不存在)' })"
        if ($procs) {
            $cur = Invoke-We @("-control", "getWallpaper")
            Write-Host "当前壁纸(CLI)  : $(if ($cur) { $cur } else { '(空)' })"
        }
        Write-Host "当前壁纸(config): $(Get-ConfigWallpaper)"
        $app = Get-Process material_desktop -ErrorAction SilentlyContinue
        Write-Host "壁纸进程       : $(if ($app) { ($app | ForEach-Object { "pid=$($_.Id)" }) -join ', ' } else { '未运行' })"
        if (Test-Path $statePath) { Write-Host "备份状态文件   : $(Get-Content $statePath -Raw)" }
    }

    "mount" {
        # 默认直接吃 tools\pack.ps1 生成的 dist\we-project（成品唯一入口），
        # 不再自己拼 project.json —— 免得两处定义漂移。
        if (-not $ExeDir) {
            $root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
            $ExeDir = Join-Path $root "dist"
        }
        $src = Join-Path $ExeDir "we-project"
        if (-not (Test-Path -LiteralPath (Join-Path $src "project.json"))) {
            throw "找不到 $src\project.json —— 先跑 tools\pack.ps1 生成 dist"
        }
        [IO.Directory]::CreateDirectory($projectDir) | Out-Null
        # 正在运行的壁纸进程会 mmap 住 icudtl.dat 等文件，必须先停掉再复制，
        # 否则 Copy-Item 报 "user-mapped section open"。WE 随后会重新拉起它。
        Get-Process material_desktop -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 800
        Copy-Item -Path (Join-Path $src "*") -Destination $projectDir -Recurse -Force
        Write-Host "已部署工程：$src → $projectDir"

        if (-not (Ensure-We)) { throw "Wallpaper Engine 启动失败" }
        Save-StateOnce
        Write-Host "加载壁纸：$projectJson"
        Invoke-We @("-control", "openWallpaper", "-file", $projectJson) | Write-Host
        Start-Sleep -Seconds 6
        $cur = Invoke-We @("-control", "getWallpaper")
        Write-Host "当前壁纸（getWallpaper）: $cur"
        $app = Get-Process material_desktop -ErrorAction SilentlyContinue
        Write-Host "material_desktop 进程    : $(if ($app) { ($app | ForEach-Object { "pid=$($_.Id) 已启动" }) -join ', ' } else { '未启动（WE 可能还没拉起来）' })"
    }

    "restore" {
        if (-not (Test-Path -LiteralPath $statePath)) { throw "没有找到备份状态文件 $statePath，无法还原" }
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $prev = "$($state.previousWallpaper)"
        if (-not $prev -and $state.previousConfigBackup -and (Test-Path -LiteralPath $state.previousConfigBackup)) {
            $raw = [IO.File]::ReadAllText($state.previousConfigBackup)
            $m = [regex]::Match($raw, '"selectedwallpapers"\s*:\s*\{[\s\S]*?"Monitor0"\s*:\s*\{\s*"file"\s*:\s*"([^"]+)"')
            if ($m.Success) { $prev = $m.Groups[1].Value }
        }
        Write-Host "还原壁纸：$prev"
        if ($prev -and (Ensure-We)) {
            # 让 WE 自己去改 config.json —— 它自己写才不会破坏文件里的中文键。
            Invoke-We @("-control", "openWallpaper", "-file", $prev) | Write-Host
            Start-Sleep -Seconds 5
        }
        Get-Process material_desktop -ErrorAction SilentlyContinue | Stop-Process -Force
        Write-Host "已停止 material_desktop 壁纸进程"
        Write-Host "当前壁纸(config)：$(Get-ConfigWallpaper)"
    }

    "unmount" {
        if (Test-Path -LiteralPath $projectDir) {
            Remove-Item -LiteralPath $projectDir -Recurse -Force
            Write-Host "已移除工程目录：$projectDir"
        }
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
    }
}
