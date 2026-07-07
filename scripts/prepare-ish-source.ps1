param(
    [string]$Destination = "External\ish",
    [string]$Repository = "https://github.com/OpenMinis/ish-arm64.git",
    [string]$Revision = "master",
    [string]$SourcePath = $env:IEXA_ISH_SOURCE_PATH,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ($SourcePath) {
    $resolvedSource = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath)
    if (-not (Test-Path -LiteralPath $resolvedSource)) {
        throw "SourcePath does not exist: $SourcePath"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedSource "iSH.xcodeproj"))) {
        throw "SourcePath does not look like an iSH checkout: $SourcePath"
    }
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Force) {
            throw "Destination already exists: $Destination. Re-run with -Force to replace it from SourcePath."
        }
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $resolvedSource -Destination $Destination -Recurse -Force
    Write-Host "Prepared iSH ARM64 source at $Destination from $resolvedSource"
    Write-Host "Guest architecture: arm64/aarch64"
    exit 0
}

if (Test-Path -LiteralPath $Destination) {
    if (Test-Path -LiteralPath (Join-Path $Destination ".git")) {
        git -C $Destination fetch --depth 1 origin $Revision
    } else {
        throw "Destination exists but is not a git checkout: $Destination"
    }
} else {
    git clone --depth 1 $Repository $Destination
}

git -C $Destination fetch --depth 1 origin $Revision
git -C $Destination reset --hard FETCH_HEAD
git -C $Destination submodule update --init --depth 1 deps/libapps deps/libarchive

Write-Host "Prepared iSH ARM64 source at $Destination"
Write-Host "Guest architecture: arm64/aarch64"
