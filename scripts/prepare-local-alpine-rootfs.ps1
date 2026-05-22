param(
    [string]$OutputPath = "Open UI\Resources\iexa-alpine-rootfs.tar.gz",
    [string]$RootFSUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86/alpine-minirootfs-3.23.4-x86.tar.gz",
    [string]$ExpectedSHA256 = "dba449a2c286f73cb1cf9b248631f3182c291f22619e1500922bd97b542263fa",
    [string[]]$PreinstallPackages = @("build-base", "g++", "make", "python3", "py3-pip")
)

$ErrorActionPreference = "Stop"

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$downloadPath = $resolvedOutput
if ($PreinstallPackages.Count -gt 0) {
    $downloadPath = Join-Path $outputDir ".iexa-alpine-minirootfs.tar.gz"
}

Write-Host "Downloading Alpine/iSH rootfs..."
Write-Host "Source: $RootFSUrl"
Write-Host "Target: $downloadPath"

Invoke-WebRequest -Uri $RootFSUrl -OutFile $downloadPath -UseBasicParsing

$actualSHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
if ($ExpectedSHA256 -and $actualSHA256 -ne $ExpectedSHA256.ToLowerInvariant()) {
    throw "SHA256 mismatch: expected $ExpectedSHA256, got $actualSHA256"
}

if ($PreinstallPackages.Count -gt 0) {
    $scriptPath = Join-Path $PSScriptRoot "preinstall-alpine-packages.py"
    & python $scriptPath $downloadPath $resolvedOutput --packages @PreinstallPackages
    if ($LASTEXITCODE -ne 0) {
        throw "preinstall-alpine-packages.py failed with exit code $LASTEXITCODE"
    }
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue

    $verifyScript = @'
import sys
import tarfile

required = {
    "usr/bin/as",
    "usr/bin/gcc",
    "usr/bin/g++",
    "usr/bin/ld",
    "usr/bin/make",
    "usr/bin/pip3",
    "usr/bin/python3",
    "usr/include/stdio.h",
    "usr/include/c++",
    "usr/lib/libstdc++.so.6",
    "usr/lib/crt1.o",
}
with tarfile.open(sys.argv[1], "r:*") as archive:
    names = set(archive.getnames())
missing = sorted(required - names)
if missing:
    raise SystemExit("Preinstalled rootfs is missing " + ", ".join(missing))
'@
    $verifyScript | python - $resolvedOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Preinstalled rootfs verification failed with exit code $LASTEXITCODE"
    }
}

$item = Get-Item -LiteralPath $resolvedOutput
Write-Host ("Done: {0:N0} bytes" -f $item.Length)
Write-Host "SHA256: $actualSHA256"
