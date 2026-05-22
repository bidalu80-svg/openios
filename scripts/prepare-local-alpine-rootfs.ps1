param(
    [string]$OutputPath = "Open UI\Resources\iexa-alpine-rootfs.tar.gz",
    [string]$RootFSUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86/alpine-minirootfs-3.23.4-x86.tar.gz",
    [string]$ExpectedSHA256 = "dba449a2c286f73cb1cf9b248631f3182c291f22619e1500922bd97b542263fa"
)

$ErrorActionPreference = "Stop"

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "Downloading Alpine/iSH rootfs..."
Write-Host "Source: $RootFSUrl"
Write-Host "Target: $resolvedOutput"

Invoke-WebRequest -Uri $RootFSUrl -OutFile $resolvedOutput -UseBasicParsing

$actualSHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedOutput).Hash.ToLowerInvariant()
if ($ExpectedSHA256 -and $actualSHA256 -ne $ExpectedSHA256.ToLowerInvariant()) {
    throw "SHA256 mismatch: expected $ExpectedSHA256, got $actualSHA256"
}

$item = Get-Item -LiteralPath $resolvedOutput
Write-Host ("Done: {0:N0} bytes" -f $item.Length)
Write-Host "SHA256: $actualSHA256"
