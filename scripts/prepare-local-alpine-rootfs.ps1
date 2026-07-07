param(
    [string]$OutputPath = "Iexa UI\Resources\iexa-alpine-rootfs.tar.gz",
    [string]$RootFSUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.3-aarch64.tar.gz",
    [string]$ExpectedSHA256 = "ead8a4b37867bd19e7417dd078748e2312c0aea364403d96758d63ea8ff261ea",
    [string]$RepositoryBaseUrl = "https://dl-cdn.alpinelinux.org/alpine/v3.21",
    [string]$Architecture = "aarch64",
    [string[]]$PreinstallPackages = @("fping")
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
    & python $scriptPath $downloadPath $resolvedOutput --base-url $RepositoryBaseUrl --arch $Architecture --packages @PreinstallPackages
    if ($LASTEXITCODE -ne 0) {
        throw "preinstall-alpine-packages.py failed with exit code $LASTEXITCODE"
    }
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue

    $verifyScript = @'
import sys
import tarfile

packages = set(sys.argv[2:])
required = set()
required_prefixes = []
if "fping" in packages:
    required.add("usr/sbin/fping")
if {"build-base", "gcc", "g++"} & packages:
    required.update({
        "usr/bin/as",
        "usr/bin/gcc",
        "usr/bin/g++",
        "usr/bin/ld",
        "usr/bin/make",
        "usr/include/stdio.h",
        "usr/lib/libstdc++.so.6",
        "usr/lib/crt1.o",
    })
    required_prefixes.append("usr/include/c++/")
if {"python3", "py3-pip"} & packages:
    required.add("usr/bin/python3")
if "py3-pip" in packages:
    required.add("usr/bin/pip3")
with tarfile.open(sys.argv[1], "r:*") as archive:
    names = set(archive.getnames())
missing = sorted(required - names)
missing.extend(prefix + "*" for prefix in required_prefixes if not any(name.startswith(prefix) for name in names))
if missing:
    raise SystemExit("Preinstalled rootfs is missing " + ", ".join(missing))
'@
    $verifyScript | python - $resolvedOutput @PreinstallPackages
    if ($LASTEXITCODE -ne 0) {
        throw "Preinstalled rootfs verification failed with exit code $LASTEXITCODE"
    }
}

$item = Get-Item -LiteralPath $resolvedOutput
Write-Host ("Done: {0:N0} bytes" -f $item.Length)
Write-Host "SHA256: $actualSHA256"
