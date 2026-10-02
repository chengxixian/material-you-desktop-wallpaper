# 把构建产物整理成一个「唯一入口」的成品目录：<工程根>\dist
#
#   dist\
#   ├── material_desktop.exe + data/ + flutter_windows.dll    ← 绿色包，双击即用（= 壁纸模式）
#   ├── we-project\                                           ← 可直接拷进 Wallpaper Engine 的应用程序壁纸工程
#   └── material-you-desktop-wallpaper-<版本>-windows-x64.zip  ← 打包分享用
#
# 用法（执行策略 Restricted，.ps1 用 ScriptBlock 载入）：
#   $sb=[ScriptBlock]::Create([IO.File]::ReadAllText("tools\pack.ps1")); & $sb
param(
    [string]$Source = "",
    [string]$Dest = ""
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if (-not $Source) { $Source = $root }
$Source = [IO.Path]::GetFullPath($Source)
if (-not $Dest) { $Dest = Join-Path $Source "dist" }
$Dest = [IO.Path]::GetFullPath($Dest)

$release = Join-Path $Source "build\windows\x64\runner\Release"
if (-not (Test-Path -LiteralPath (Join-Path $release "material_desktop.exe"))) {
    throw "找不到 Release 产物：$release（先 flutter build windows --release）"
}

# 版本号取自 pubspec.yaml
$version = "0.0.0"
foreach ($line in (Get-Content -LiteralPath (Join-Path $Source "pubspec.yaml"))) {
    if ($line -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { $version = $Matches[1]; break }
}

Write-Host "归档 → $Dest"
if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
[IO.Directory]::CreateDirectory($Dest) | Out-Null

# 1) 绿色包（放在 dist 顶层，双击 material_desktop.exe 即壁纸）
Get-ChildItem -LiteralPath $release -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force
}

# 2) Wallpaper Engine 应用程序壁纸工程
$we = Join-Path $Dest "we-project"
[IO.Directory]::CreateDirectory($we) | Out-Null
Get-ChildItem -LiteralPath $release -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $we -Recurse -Force
}
$projectJson = @"
{
	"file" : "material_desktop.exe",
	"general" : 
	{
		"properties" : 
		{
			"schemecolor" : 
			{
				"order" : 0,
				"text" : "ui_browse_properties_scheme_color",
				"type" : "color",
				"value" : "0.4 0.31 0.64"
			}
		}
	},
	"title" : "Material Desktop · Flutter 桌面小组件"
}
"@
[IO.File]::WriteAllText((Join-Path $we "project.json"), $projectJson, (New-Object System.Text.UTF8Encoding($false)))

# 3) 打包分享用的 zip（只压绿色包本身，不含 we-project 与 zip 自己）
$zip = Join-Path $Dest "material-you-desktop-wallpaper-$version-windows-x64.zip"
$items = @(Join-Path $Dest "material_desktop.exe") + @(
    Get-ChildItem -LiteralPath $Dest -Force |
        Where-Object { $_.Name -in @("data", "flutter_windows.dll", "native_assets.json") } |
        ForEach-Object { $_.FullName }
)
Compress-Archive -LiteralPath $items -DestinationPath $zip -CompressionLevel Optimal -Force

$bundle = (Get-ChildItem -LiteralPath $Dest -Force |
    Where-Object { $_.Name -notin @("we-project", "dist") -and $_.Extension -ne ".zip" } |
    Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
Write-Host ""
Write-Host "完成。成品都在这一个目录里：" -ForegroundColor Green
Write-Host "  绿色包（双击即壁纸）: $Dest\material_desktop.exe"
Write-Host "  WE 工程             : $we\project.json"
Write-Host "  分享用 zip          : $zip  ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)"
Write-Host "  绿色包体积          : $([math]::Round($bundle/1MB,1)) MB"
