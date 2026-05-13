param(
    [string]$Branch = "codex/clean-from-25723031799",
    [string]$Workflow = "build-ios-ipa.yml",
    [string]$TrustedBase = "47f9bb35d441d8f45d560b5d027dac9a4292dea8",
    [int]$RunLookupSeconds = 90,
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

$repoRoot = (Invoke-Git rev-parse --show-toplevel).Trim()
Set-Location -LiteralPath $repoRoot

$currentBranch = (Invoke-Git branch --show-current).Trim()
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
Write-Host "Build HEAD:    $head"

Invoke-Git push origin "HEAD:refs/heads/$Branch" | Write-Host

$remote = (& git ls-remote origin "refs/heads/$Branch")
if ($LASTEXITCODE -ne 0 -or -not $remote) {
    throw "Could not read origin/$Branch."
}
$remoteHead = ($remote -split "\s+")[0]
if ($remoteHead -ne $head) {
    throw "origin/$Branch is $remoteHead, expected $head."
}

$startedAt = Get-Date
Invoke-Gh workflow run $Workflow --ref $Branch | Write-Host

$deadline = $startedAt.AddSeconds($RunLookupSeconds)
$run = $null
do {
    Start-Sleep -Seconds 3
    $runsJson = Invoke-Gh run list --workflow $Workflow --branch $Branch --json "databaseId,headSha,status,conclusion,url,createdAt,event" -L 20
    $runs = $runsJson | ConvertFrom-Json
    $run = $runs |
        Where-Object { $_.headSha -eq $head -and $_.event -eq "workflow_dispatch" } |
        Sort-Object createdAt -Descending |
        Select-Object -First 1
} while (-not $run -and (Get-Date) -lt $deadline)

if (-not $run) {
    throw "No workflow_dispatch run found for HEAD $head on $Branch."
}

Write-Host "Run ID:        $($run.databaseId)"
Write-Host "Run URL:       $($run.url)"
Write-Host "Run headSha:   $($run.headSha)"

if ($run.headSha -ne $head) {
    throw "Workflow run headSha mismatch: $($run.headSha), expected $head."
}

if (-not $NoWatch) {
    & gh run watch $run.databaseId --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "Workflow run $($run.databaseId) failed."
    }
}

$viewJson = Invoke-Gh run view $run.databaseId --json "headSha,conclusion,url"
$view = $viewJson | ConvertFrom-Json
if ($view.headSha -ne $head) {
    throw "Final workflow headSha mismatch: $($view.headSha), expected $head."
}

Write-Host "Verified new IPA run for HEAD $head"
Write-Host $view.url
