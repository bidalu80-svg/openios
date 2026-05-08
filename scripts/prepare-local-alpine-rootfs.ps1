param(
    [string]$OutputPath = "Open UI\Resources\iexa-alpine-rootfs.tar.gz",
    [string]$RootFSUrl = "https://github.com/ish-app/roots/releases/download/g00712ff0a54b2839c5aa1a8ed758003ca65357dc/appstore-apk.tar.gz"
)

$ErrorActionPreference = "Stop"

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "Downloading Alpine/iSH rootfs..."
Write-Host "Source: $RootFSUrl"
Write-Host "Target: $resolvedOutput"

Invoke-WebRequest -Uri $RootFSUrl -OutFile $resolvedOutput -UseBasicParsing

$item = Get-Item -LiteralPath $resolvedOutput
Write-Host ("Done: {0:N0} bytes" -f $item.Length)
