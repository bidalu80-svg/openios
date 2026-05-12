param(
    [string]$Destination = "External\ish",
    [string]$Repository = "https://github.com/ish-app/ish.git"
)

$ErrorActionPreference = "Stop"

if (Test-Path -LiteralPath $Destination) {
    if (Test-Path -LiteralPath (Join-Path $Destination ".git")) {
        git -C $Destination fetch --depth 1 origin
        git -C $Destination reset --hard FETCH_HEAD
    } else {
        throw "Destination exists but is not a git checkout: $Destination"
    }
} else {
    git clone --depth 1 $Repository $Destination
}

git -C $Destination submodule update --init --depth 1 deps/libapps deps/libarchive

Write-Host "Prepared iSH source at $Destination"
Write-Host "Note: deps/linux is intentionally not fetched for the default iOS iSH kernel path."
