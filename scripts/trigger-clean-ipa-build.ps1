param(
    [string]$Branch = "",
    [string]$Workflow = "build-ios-ipa.yml",
    [string]$TrustedBase = "47f9bb35d441d8f45d560b5d027dac9a4292dea8",
    [int]$RunLookupSeconds = 90,
    [switch]$UseGitPush,
    [switch]$NoWatch
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $output = & git @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed"
    }
    return $output
}

function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $output = & gh @Args
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Args -join ' ') failed"
    }
    return $output
}

function Invoke-GhApi {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null
    )

    if ($null -eq $Body) {
        return Invoke-Gh api "-X" $Method $Path
    }

    $temp = New-TemporaryFile
    try {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($temp.FullName, $json, $utf8NoBom)
        return Invoke-Gh api "-X" $Method $Path "--input" $temp
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-GitQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "git"
    $psi.Arguments = $Args -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardOutput.ReadToEnd() | Out-Null
    $process.StandardError.ReadToEnd() | Out-Null
    $process.WaitForExit()
    return $process.ExitCode -eq 0
}

function Get-RemoteBranchSha {
    param(
        [string]$Repo,
        [string]$BranchName
    )

    $refJson = & gh api "-X" GET "repos/$Repo/git/ref/heads/$BranchName" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $refJson) {
        return $null
    }
    return (($refJson | ConvertFrom-Json).object.sha)
}

function Get-ChangedPaths {
    param([string]$BaseSha)

    $lines = & git diff --name-status -M $BaseSha HEAD --
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --name-status failed"
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if (-not $line) {
            continue
        }
        $parts = $line -split "`t"
        $status = $parts[0]
        if ($status.StartsWith("R")) {
            $oldPath = $parts[1]
            $newPath = $parts[2]
            $items.Add([pscustomobject]@{ Status = "D"; Path = $oldPath }) | Out-Null
            $items.Add([pscustomobject]@{ Status = "A"; Path = $newPath }) | Out-Null
        } elseif ($status.StartsWith("C")) {
            $newPath = $parts[2]
            $items.Add([pscustomobject]@{ Status = "A"; Path = $newPath }) | Out-Null
        } else {
            $path = $parts[1]
            $items.Add([pscustomobject]@{ Status = $status.Substring(0, 1); Path = $path }) | Out-Null
        }
    }

    return $items
}

function New-GitHubBlob {
    param(
        [string]$Repo,
        [string]$Path
    )

    $blob = (Invoke-Git rev-parse "HEAD:$Path").Trim()
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "git"
    $psi.Arguments = "cat-file blob $blob"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $stream = [System.IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git cat-file blob $blob failed: $stderr"
        }
        $bytes = $stream.ToArray()
    } finally {
        $stream.Dispose()
        $process.Dispose()
    }

    $body = @{
        content = [Convert]::ToBase64String($bytes)
        encoding = "base64"
    }
    return ((Invoke-GhApi POST "repos/$Repo/git/blobs" $body | ConvertFrom-Json).sha)
}

function Get-GitMode {
    param([string]$Path)

    $mode = (& git ls-tree HEAD -- $Path)
    if ($LASTEXITCODE -ne 0 -or -not $mode) {
        return "100644"
    }
    return (($mode -split "\s+")[0])
}

function Publish-HeadWithGitHubApi {
    param(
        [string]$BranchName,
        [string]$FallbackBaseSha
    )

    $repo = (Invoke-Gh repo view --json nameWithOwner -q ".nameWithOwner").Trim()
    $remoteSha = Get-RemoteBranchSha -Repo $repo -BranchName $BranchName
    $baseSha = if ($remoteSha) { $remoteSha } else { $FallbackBaseSha }

    $baseIsUsable = (Test-GitQuiet cat-file "-e" "$baseSha^{commit}") -and
        (Test-GitQuiet merge-base --is-ancestor $baseSha HEAD)
    if (-not $baseIsUsable) {
        Write-Host "Remote base $baseSha is not an ancestor of local HEAD; using trusted base $FallbackBaseSha and force-updating $BranchName."
        $baseSha = $FallbackBaseSha
    }

    $changes = @(Get-ChangedPaths -BaseSha $baseSha)
    if ($changes.Count -eq 0) {
        Write-Host "Remote branch is already up to date with local HEAD content."
        return $baseSha
    }

    Write-Host "Uploading $($changes.Count) changed path(s) through GitHub API..."
    $tree = @()
    foreach ($change in $changes) {
        if ($change.Status -eq "D") {
            $tree += @{
                path = $change.Path
                mode = "100644"
                type = "blob"
                sha = $null
            }
            continue
        }

        $blobSha = New-GitHubBlob -Repo $repo -Path $change.Path
        $tree += @{
            path = $change.Path
            mode = Get-GitMode -Path $change.Path
            type = "blob"
            sha = $blobSha
        }
    }

    $treeSha = ((Invoke-GhApi POST "repos/$repo/git/trees" @{
        base_tree = $baseSha
        tree = $tree
    } | ConvertFrom-Json).sha)

    $message = (Invoke-Git log -1 --format=%B HEAD) -join "`n"
    if (-not $message.Trim()) {
        $message = "Update $BranchName"
    }
    $commitSha = ((Invoke-GhApi POST "repos/$repo/git/commits" @{
        message = $message
        tree = $treeSha
        parents = @($baseSha)
    } | ConvertFrom-Json).sha)

    if ($remoteSha) {
        Invoke-GhApi PATCH "repos/$repo/git/refs/heads/$BranchName" @{
            sha = $commitSha
            force = $true
        } | Out-Null
    } else {
        Invoke-GhApi POST "repos/$repo/git/refs" @{
            ref = "refs/heads/$BranchName"
            sha = $commitSha
        } | Out-Null
    }

    return $commitSha
}

$repoRoot = (Invoke-Git rev-parse --show-toplevel).Trim()
Set-Location -LiteralPath $repoRoot

$currentBranch = (Invoke-Git branch --show-current).Trim()
if (-not $Branch) {
    $Branch = $currentBranch
}
if ($currentBranch -ne $Branch) {
    throw "Refusing to build from '$currentBranch'. Switch to '$Branch' first."
}

$head = (Invoke-Git rev-parse HEAD).Trim()
& git merge-base --is-ancestor $TrustedBase HEAD
if ($LASTEXITCODE -ne 0) {
    throw "HEAD $head does not contain trusted base $TrustedBase."
}

$dirtyTracked = (& git status --porcelain --untracked-files=no)
if ($dirtyTracked) {
    throw "Tracked files are not committed. Commit or discard tracked changes before building."
}

Write-Host "Trusted base: $TrustedBase"
Write-Host "Build branch:  $Branch"
Write-Host "Local HEAD:    $head"

if ($UseGitPush) {
    Invoke-Git push origin "HEAD:refs/heads/$Branch" | Write-Host

    $remote = (& git ls-remote origin "refs/heads/$Branch")
    if ($LASTEXITCODE -ne 0 -or -not $remote) {
        throw "Could not read origin/$Branch."
    }
    $buildHead = ($remote -split "\s+")[0]
} else {
    $buildHead = Publish-HeadWithGitHubApi -BranchName $Branch -FallbackBaseSha $TrustedBase
}
Write-Host "Remote HEAD:   $buildHead"

$startedAt = Get-Date
Invoke-Gh workflow run $Workflow --ref $Branch | Write-Host

$deadline = $startedAt.AddSeconds($RunLookupSeconds)
$run = $null
do {
    Start-Sleep -Seconds 3
    $runsJson = Invoke-Gh run list --workflow $Workflow --branch $Branch --json "databaseId,headSha,status,conclusion,url,createdAt,event" -L 20
    $runs = $runsJson | ConvertFrom-Json
    $run = $runs |
        Where-Object { $_.headSha -eq $buildHead -and $_.event -eq "workflow_dispatch" } |
        Sort-Object createdAt -Descending |
        Select-Object -First 1
} while (-not $run -and (Get-Date) -lt $deadline)

if (-not $run) {
    throw "No workflow_dispatch run found for HEAD $buildHead on $Branch."
}

Write-Host "Run ID:        $($run.databaseId)"
Write-Host "Run URL:       $($run.url)"
Write-Host "Run headSha:   $($run.headSha)"

if ($run.headSha -ne $buildHead) {
    throw "Workflow run headSha mismatch: $($run.headSha), expected $buildHead."
}

if (-not $NoWatch) {
    & gh run watch $run.databaseId --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "Workflow run $($run.databaseId) failed."
    }
}

$viewJson = Invoke-Gh run view $run.databaseId --json "headSha,conclusion,url"
$view = $viewJson | ConvertFrom-Json
if ($view.headSha -ne $buildHead) {
    throw "Final workflow headSha mismatch: $($view.headSha), expected $buildHead."
}

Write-Host "Verified new IPA run for remote HEAD $buildHead"
Write-Host $view.url
