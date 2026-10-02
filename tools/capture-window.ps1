# 真实窗口截图：启动 EXE，等待其渲染出首帧，然后用 PrintWindow(PW_RENDERFULLCONTENT)
# 抓取窗口位图。用于产出「真实运行」证据，而不是设计稿。
#
# 用法（本机执行策略为 Restricted，需用 ScriptBlock 方式载入）：
#   $sb = [ScriptBlock]::Create([IO.File]::ReadAllText("tools\capture-window.ps1"))
#   & $sb -Exe "build\windows\x64\runner\Release\material_desktop.exe" -Arguments "--settings" -Out "shots\settings.png"
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Arguments = "",
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$WaitSeconds = 10,
    [string]$TitleMatch = "material_desktop",
    # 窗口出现后再等多久才截图（等首帧 + 天气这类异步请求回来）
    [int]$SettleMs = 8000,
    # Window = PrintWindow（只抓该窗口）；Screen = 抓整屏（能反映真实观感）
    [ValidateSet("Window", "Screen")][string]$Mode = "Window",
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
if (-not ("WinCapture" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class WinCapture {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // flags: 0 = WM_PRINT, 2 = PW_RENDERFULLCONTENT (DWM 合成窗口必需)
    public static string Grab(IntPtr hWnd, string path, uint flags) {
        if (hWnd == IntPtr.Zero) { return "no-window-handle"; }
        RECT r;
        if (!GetWindowRect(hWnd, out r)) { return "GetWindowRect failed"; }
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) { return "bad-rect " + w + "x" + h; }
        using (Bitmap bmp = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                bool ok = PrintWindow(hWnd, hdc, flags);
                g.ReleaseHdc(hdc);
                bmp.Save(path, ImageFormat.Png);
                return (ok ? "ok" : "PrintWindow-false") + " " + w + "x" + h;
            }
        }
    }

    // 抓整屏（含桌面与所有窗口），用于验证「用户实际看到什么」
    public static string GrabScreen(string path) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        using (Bitmap bmp = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(0, 0, 0, 0, new System.Drawing.Size(w, h));
            }
            bmp.Save(path, ImageFormat.Png);
            return "screen " + w + "x" + h;
        }
    }
}
"@
}

# ⚠️ 关键：powershell.exe 默认是 DPI-unaware 进程。
# 在 175% 缩放的屏幕上，GetWindowRect/GetSystemMetrics 会返回被虚拟化后的
# 逻辑尺寸（2560x1600 → 1463x914），PrintWindow/CopyFromScreen 于是只截到
# 窗口左上角的一小块 —— 看上去就像「右上角组件没渲染」。先把本进程改成
# DPI-aware，拿到的才是真实物理像素。
[WinCapture]::SetProcessDPIAware() | Out-Null

$exePath = (Resolve-Path -LiteralPath $Exe).Path
$outPath = [IO.Path]::GetFullPath($Out)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outPath)) | Out-Null
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

$procArgs = @()
if ($Arguments -ne "") { $procArgs = $Arguments.Split(" ") }
$proc = Start-Process -FilePath $exePath -ArgumentList $procArgs -PassThru

$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $proc.Refresh()
    if ($proc.HasExited) { throw "进程提前退出，exit=$($proc.ExitCode)" }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and $proc.MainWindowTitle -like "*$TitleMatch*") {
        $hwnd = $proc.MainWindowHandle
        # 首帧之后再等一会儿，保证 Flutter 已经把内容画出来、异步数据也回来了
        Start-Sleep -Milliseconds $SettleMs
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $proc.MainWindowHandle }
        break
    }
}

$result = if ($Mode -eq "Screen") { [WinCapture]::GrabScreen($outPath) } else { [WinCapture]::Grab($hwnd, $outPath, 2) }
Write-Host "mode     : $Mode"
Write-Host "exe      : $exePath $Arguments"
Write-Host "pid/hwnd: $($proc.Id) / $hwnd  title='$($proc.MainWindowTitle)'"
Write-Host "capture  : $result"
if (Test-Path -LiteralPath $outPath) {
    Write-Host "png      : $outPath ($((Get-Item -LiteralPath $outPath).Length) bytes)"
} else {
    Write-Host "png      : MISSING"
}
if (-not $KeepRunning) { Stop-Process -Id $proc.Id -Force }
