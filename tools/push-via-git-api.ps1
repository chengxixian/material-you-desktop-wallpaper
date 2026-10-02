# 用 gh 的 Git Data API 把当前 git 仓库推上 GitHub。
#
# 为什么需要它：本机 git 直连 GitHub 会挂在 schannel 的
# CRYPT_E_NO_REVOCATION_CHECK（吊销检查不可达），`git push` 直接失败；
# 而 gh 走 Go 自带的证书栈能通。Contents API 也不行 —— 它对单文件有 1MB 限制，
# 本仓库的截图有 1.4MB+ 的。所以走 Git Data API：
#   blobs → tree → commit → ref，全程只读本地 git 对象，推完再逐一比对 sha。
#
# 用法：
#   $sb=[ScriptBlock]::Create([IO.File]::ReadAllText("tools\push-via-git-api.ps1"))
#   & $sb -Owner chengxixian -Repo material-you-desktop-wallpaper
param(
    [Parameter(Mandatory = $true)][string]$Owner,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Branch = "main",
    [string]$Message = "",
    [string]$Gh = "D:\tool\gh\gh.exe",
    [string]$Git = "",
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Gh)) { $Gh = (Get-Command gh.exe -ErrorAction SilentlyContinue).Source }
if (-not $Gh) { throw "找不到 gh.exe，用 -Gh 指定路径" }
if (-not $Message) { $Message = (git log -1 --pretty=%B) }
if (-not $Git) {
    $c = Get-Command git.exe -ErrorAction SilentlyContinue
    $Git = if ($c) { $c.Source } elseif (Test-Path "D:\tool\PortableGit\cmd\git.exe") { "D:\tool\PortableGit\cmd\git.exe" } else { "git" }
}

# 仓库根：本脚本假定在工程根执行；用 git 自己确认，顺便让子进程有正确的 CWD。
$gitDir = & $Git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $gitDir) { throw "当前目录不是 git 仓库：$((Get-Location).Path)" }
$repoRoot = ([string]$gitDir).Trim()
Write-Host "仓库根：$repoRoot"

# 取某个 blob 的**原始字节**。
# ⚠️ 不能用 `git cat-file blob <sha> > file`：PowerShell 的 `>` 会先把字节按文本解码，
#    二进制（比如 png）会被毁掉。必须走 .NET 进程的重定向流。
# ⚠️ 也不能直接读工作区文件：仓库里启用了 `* text=auto`，工作区可能是 CRLF 而 blob 是 LF，
#    直接上传会得到与本地 commit **不同**的内容（实测踩到过 17 个文件 sha 不一致）。
function Get-BlobBytes([string]$sha) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Git
    $psi.Arguments = "cat-file blob $sha"
    # ⚠️ PowerShell 的 Set-Location 不会改 .NET 进程的当前目录，
    #    不显式指定 WorkingDirectory 的话子进程会在别处跑，报 "not a git repository"。
    $psi.WorkingDirectory = $repoRoot
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    try {
        # ⚠️ PowerShell 会把函数里每个**未被捕获**的表达式结果都当作返回值输出！
        #    `$p.WaitForExit()` 返回 bool，不吞掉的话这个函数就返回 @($true, <bytes>)，
        #    后面 ToBase64String 拿到垃圾 → gh 收到非法请求体。
        $null = $p.StandardOutput.BaseStream.CopyTo($ms)
        $null = $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "git cat-file blob 失败：$sha" }
        return ,$ms.ToArray()
    } finally {
        $ms.Dispose()
        $p.Dispose()
    }
}

function Invoke-Gh([string[]]$ghArgs) {
    # gh 在非 2xx 时往 stderr 写，而 $ErrorActionPreference=Stop 会把它升级成终止错误
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Gh @ghArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh 调用失败：gh $($ghArgs -join ' ')`n$out" }
        return ($out | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-GhSoft([string[]]$ghArgs) {
    # 允许失败：空仓库探测 branch 会返回 409，这里当作「不存在」而不是错误
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Gh @ghArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($out | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $prev
    }
}

$tmp = Join-Path $env:TEMP "gh-blob-$([guid]::NewGuid().ToString('N')).json"
try {
    # 0) GitHub 不允许在**完全空**的仓库里建 blob（409 Git Repository is empty）。
    #    先用 Contents API 放一个占位文件把仓库「点亮」（它会自动建出首个 commit
    #    和 main 分支）；随后我们推一个**无 parent 的根 commit** 并把分支强制指过去，
    #    所以占位文件只存在于一个会被丢弃的 commit 里，最终 tree 完全是本仓库内容。
    $head = Invoke-GhSoft @("api", "repos/$Owner/$Repo/git/ref/heads/$Branch", "--jq", ".object.sha")
    if (-not $head) {
        Write-Host "仓库是空的，先 bootstrap 一个占位 commit ..."
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("bootstrap`n"))
        Invoke-Gh @("api", "--method", "PUT", "repos/$Owner/$Repo/contents/.gitkeep",
                    "-f", "message=chore: bootstrap repository", "-f", "content=$b64") | Out-Null
        Write-Host "bootstrap 完成（这个 commit 随后会被无 parent 的根 commit 取代）"
    }
    # 1) 逐个文件建 blob。内容直接取**工作区字节**：本仓库文件本来就是 LF，
    #    与 git add 后的 blob 一致；推完第 4 步会用 sha 逐一校验，不一致会报出来。
    $entries = @()
    $lines = git ls-files -s
    Write-Host "准备推送 $($lines.Count) 个文件 → $Owner/$Repo ($Branch)"
    $i = 0
    foreach ($line in $lines) {
        # 形如：100644 <sha> 0<TAB>path
        $m = [regex]::Match($line, '^(\d{6})\s+([0-9a-f]{40})\s+\d+\t(.+)$')
        if (-not $m.Success) { throw "无法解析 git ls-files 输出：$line" }
        $mode, $localSha, $path = $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value
        # 内容取自 git 对象库（= 本地 commit 里的内容），不是工作区文件
        $bytes = Get-BlobBytes $localSha
        $b64 = [Convert]::ToBase64String($bytes)
        [IO.File]::WriteAllText($tmp, (@{ content = $b64; encoding = "base64" } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $sha = Invoke-Gh @("api", "--method", "POST", "repos/$Owner/$Repo/git/blobs", "--input", $tmp, "--jq", ".sha")
        $entries += [ordered]@{ path = $path; mode = $mode; type = "blob"; sha = $sha }
        $i++
        if ($i % 10 -eq 0 -or $i -eq $lines.Count) { Write-Host "  blob $i/$($lines.Count)" }
    }

    # 2) tree（Git Data API 的 tree 支持直接写完整路径，父目录会自动建，不需要 .gitkeep）
    [IO.File]::WriteAllText($tmp, (@{ tree = $entries } | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $tree = Invoke-Gh @("api", "--method", "POST", "repos/$Owner/$Repo/git/trees", "--input", $tmp, "--jq", ".sha")
    Write-Host "tree   = $tree"

    # 3) commit（空仓库 → 没有 parent）
    [IO.File]::WriteAllText($tmp, (@{ message = $Message; tree = $tree; parents = @() } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $commit = Invoke-Gh @("api", "--method", "POST", "repos/$Owner/$Repo/git/commits", "--input", $tmp, "--jq", ".sha")
    Write-Host "commit = $commit"

    # 4) 建/更新分支引用
    $exists = Invoke-Gh @("api", "repos/$Owner/$Repo/git/ref/heads/$Branch", "--jq", ".object.sha")
    if ($exists) {
        Invoke-Gh @("api", "--method", "PATCH", "repos/$Owner/$Repo/git/refs/heads/$Branch", "-f", "sha=$commit", "-F", "force=true") | Out-Null
        Write-Host "分支 $Branch 已更新（原 $exists → $commit）"
    } else {
        Invoke-Gh @("api", "--method", "POST", "repos/$Owner/$Repo/git/refs", "-f", "ref=refs/heads/$Branch", "-f", "sha=$commit") | Out-Null
        Write-Host "分支 $Branch 已创建"
    }

    # 5) 校验：远端每个 blob 的 sha 必须与本地 git 索引一致
    #    ⚠️ 不要给 gh api 传带空格/引号的 --jq 表达式：PowerShell 转义到原生进程时
    #    会被拆成多个参数（报 "accepts 1 arg(s), received 2"）。这里取原始 JSON 自己解析。
    if (-not $SkipVerify) {
        $remote = @{}
        $json = Invoke-Gh @("api", "repos/$Owner/$Repo/git/trees/$Branch`?recursive=1")
        foreach ($node in ($json | ConvertFrom-Json).tree) {
            if ($node.type -eq "blob") { $remote[$node.path] = $node.sha }
        }
        $bad = 0
        foreach ($e in $entries) {
            if (-not $remote.ContainsKey($e.path)) { Write-Host "⚠ 远端缺少：$($e.path)"; $bad++; continue }
            if ($remote[$e.path] -ne $e.sha) { Write-Host "⚠ sha 不一致：$($e.path)"; $bad++ }
        }
        Write-Host ("校验：{0} 个文件，{1} 个不一致" -f $entries.Count, $bad)
        if ($bad -gt 0) { throw "远端内容与本地不一致" }
        # 最强校验：整棵 tree 的 sha 应该与本地 HEAD 的 tree 完全一致
        $localTree = (git rev-parse "HEAD^{tree}").Trim()
        $remoteTree = (& $Gh api "repos/$Owner/$Repo/git/trees/$Branch" 2>$null | Out-String).Trim() | ConvertFrom-Json
        if ($remoteTree.sha) {
            Write-Host "本地 tree = $localTree"
            Write-Host "远端 tree = $($remoteTree.sha)"
            if ($remoteTree.sha -ne $localTree) { throw "远端 tree 与本地 HEAD 不一致" }
            Write-Host "✅ 远端内容与本地 commit 逐字节一致"
        }
    }

    # 让本地仓库知道远端状态（以后 git status 有对比基准）。
    # 远端 commit 是 API 造的、本地没有这个对象，所以这里 best-effort。
    try { git update-ref "refs/remotes/origin/$Branch" $commit } catch { Write-Host "（本地 origin/$Branch 引用未更新：$($_.Exception.Message)）" }
    git remote remove origin 2>$null | Out-Null
    git remote add origin "https://github.com/$Owner/$Repo.git"
    Write-Host "完成：https://github.com/$Owner/$Repo/tree/$Branch"
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
