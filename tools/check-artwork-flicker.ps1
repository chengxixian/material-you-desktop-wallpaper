# 验证「音乐封面不再闪」：连续抓 N 帧桌面，比较封面区域的像素是否稳定。
#
# 原理：壁纸进程每秒轮询一次媒体会话。修复前每次都会回传封面字节 →
# Dart 侧每秒 new 一个 Uint8List → MemoryImage 身份变化 → Flutter 每秒重新解码，
# 视觉上封面一直在闪（同时白烧 CPU）。修复后封面字节只在换歌时回传一次，
# 因此**同一秒间隔的多帧里，封面区域的像素必须完全一致**。
#
# 封面区域坐标是按本机 2560x1600 / 175% 缩放、右侧组件栏 400 逻辑像素宽算出来的；
# 换个分辨率用 -CoverBox 覆盖。
#
# 用法：
#   $sb=[ScriptBlock]::Create([IO.File]::ReadAllText("tools\check-artwork-flicker.ps1")); & $sb
param(
    [int]$Frames = 4,
    [int]$IntervalMs = 1200,
    [string]$OutDir = "",
    [int[]]$CoverBox = @(1951, 1140, 2085, 1310),  # left, top, right, bottom
    [switch]$KeepFrames
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $root "shots\_flicker" }
[IO.Directory]::CreateDirectory($OutDir) | Out-Null

Add-Type -AssemblyName System.Drawing
if (-not ("FlickerCheck" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

public class FlickerCheck {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);

    public static string Grab(string path) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        using (Bitmap b = new Bitmap(w, h)) {
            using (Graphics g = Graphics.FromImage(b)) { g.CopyFromScreen(0, 0, 0, 0, new Size(w, h)); }
            b.Save(path, ImageFormat.Png);
        }
        return w + "x" + h;
    }

    // 裁剪封面区域并返回其像素的 sha256（同一画面 → 同一个哈希）
    public static string CropHash(string path, int l, int t, int r, int bt) {
        using (Bitmap src = new Bitmap(path))
        using (Bitmap crop = src.Clone(new Rectangle(l, t, r - l, bt - t), PixelFormat.Format32bppArgb)) {
            byte[] raw = ToBytes(crop);
            using (SHA256 sha = SHA256.Create()) {
                return BitConverter.ToString(sha.ComputeHash(raw)).Replace("-", "").Substring(0, 16);
            }
        }
    }

    // 两帧之间不同像素的数量 + 差异的纵向范围（用来判断「变化的是不是只有时钟」）
    public static string Diff(string a, string b, int threshold) {
        using (Bitmap ba = new Bitmap(a)) using (Bitmap bb = new Bitmap(b)) {
            byte[] x = ToBytes(ba), y = ToBytes(bb);
            int diff = 0, minRow = int.MaxValue, maxRow = -1, stride = ba.Width * 4;
            for (int i = 0; i < x.Length; i += 4) {
                int d = Math.Abs(x[i] - y[i]) + Math.Abs(x[i + 1] - y[i + 1]) + Math.Abs(x[i + 2] - y[i + 2]);
                if (d > threshold) {
                    diff++;
                    int row = (i / stride);
                    if (row < minRow) minRow = row;
                    if (row > maxRow) maxRow = row;
                }
            }
            return diff + "|" + (diff == 0 ? "-" : minRow + "-" + maxRow);
        }
    }

    static byte[] ToBytes(Bitmap bmp) {
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            byte[] buf = new byte[d.Stride * bmp.Height];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            return buf;
        } finally { bmp.UnlockBits(d); }
    }
}
"@
}

[FlickerCheck]::SetProcessDPIAware() | Out-Null

$p = Get-Process material_desktop -ErrorAction SilentlyContinue
if (-not $p) { throw "没有正在运行的壁纸进程（material_desktop.exe），先跑 tools\we-mount.ps1 -Action mount" }
Write-Host "壁纸进程 pid=$($p.Id)  |  封面区域 = $($CoverBox -join ',')"

$shell = New-Object -ComObject Shell.Application
$files = @()
try {
    $shell.MinimizeAll()   # 让桌面完整露出来（壁纸在桌面层，不受影响）
    Start-Sleep -Seconds 3
    for ($i = 1; $i -le $Frames; $i++) {
        $f = Join-Path $OutDir ("frame$i.png")
        $size = [FlickerCheck]::Grab($f)
        $files += $f
        Write-Host ("  帧 {0}: {1}  {2}" -f $i, $size, $f)
        if ($i -lt $Frames) { Start-Sleep -Milliseconds $IntervalMs }
    }
} finally {
    $shell.UndoMinimizeAll()
}

Write-Host ""
Write-Host "── 封面区域 sha（必须全部相同）──"
$hashes = @()
foreach ($f in $files) {
    $h = [FlickerCheck]::CropHash($f, $CoverBox[0], $CoverBox[1], $CoverBox[2], $CoverBox[3])
    $hashes += $h
    Write-Host ("  {0}  {1}" -f (Split-Path -Leaf $f), $h)
}
$unique = ($hashes | Select-Object -Unique).Count

Write-Host ""
Write-Host "── 相邻帧整屏差异（变化应该只在时钟那几行）──"
for ($i = 1; $i -lt $files.Count; $i++) {
    $d = [FlickerCheck]::Diff($files[$i - 1], $files[$i], 24)
    $parts = $d.Split("|")
    Write-Host ("  帧{0}→帧{1}: 不同像素 {2}，纵向范围 {3}" -f $i, ($i + 1), $parts[0], $parts[1])
}

Write-Host ""
if ($unique -eq 1) {
    Write-Host "✅ 封面区域在 $Frames 帧（间隔 ${IntervalMs}ms）内完全一致 —— 封面不闪了" -ForegroundColor Green
} else {
    Write-Host "❌ 封面区域出现 $unique 种不同画面 —— 仍在闪烁" -ForegroundColor Red
}
if (-not $KeepFrames) { Remove-Item -LiteralPath $OutDir -Recurse -Force -ErrorAction SilentlyContinue }
# 注意：本机是 Windows PowerShell 5.1，没有 ?: 三元运算符
if ($unique -eq 1) { exit 0 } else { exit 2 }
