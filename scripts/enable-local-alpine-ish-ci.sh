#!/usr/bin/env bash
set -euo pipefail

project_file="${1:-Open UI.xcodeproj/project.pbxproj}"
ish_products="${2:-$PWD/.build/ish-products}"
ish_dir="${3:-External/ish}"

python3 - "$project_file" "$ish_products" "$ish_dir" <<'PY'
from pathlib import Path
import sys

project_file = Path(sys.argv[1])
ish_products = Path(sys.argv[2]).resolve()
ish_dir = Path(sys.argv[3])
s = project_file.read_text()

debug_marker = '\t\t38EB668E2F39CE5C00AED774 /* Debug */ = {\n'
release_marker = '\t\t38EB668F2F39CE5C00AED774 /* Release */ = {\n'

def patch_build_settings(block: str) -> str:
    if 'IEXA_LOCAL_ALPINE_ISH=1' not in block:
        block = block.replace(
            '\t\t\t\tDEVELOPMENT_TEAM = 6ARX8PF3MT;\n',
            '\t\t\t\tDEVELOPMENT_TEAM = 6ARX8PF3MT;\n'
            '\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n'
            '\t\t\t\t\t"$(inherited)",\n'
            '\t\t\t\t\t"ISH_INTERNAL=1",\n'
            '\t\t\t\t\t"IEXA_LOCAL_ALPINE_ISH=1",\n'
            '\t\t\t\t);\n'
        )
    if 'External/ish' not in block:
        block = block.replace(
            '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.1;\n',
            '\t\t\t\tHEADER_SEARCH_PATHS = (\n'
            '\t\t\t\t\t"$(inherited)",\n'
            f'\t\t\t\t\t"{ish_dir.as_posix()}",\n'
            f'\t\t\t\t\t"{ish_dir.as_posix()}/deps/libarchive/libarchive",\n'
            '\t\t\t\t);\n'
            '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.1;\n'
        )
    if str(ish_products) not in block:
        block = block.replace(
            '\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n',
            '\t\t\t\tLIBRARY_SEARCH_PATHS = (\n'
            '\t\t\t\t\t"$(inherited)",\n'
            f'\t\t\t\t\t"{ish_products.as_posix()}",\n'
            '\t\t\t\t);\n'
            '\t\t\t\tOTHER_LDFLAGS = (\n'
            '\t\t\t\t\t"$(inherited)",\n'
            '\t\t\t\t\t"-Wl,-force_load",\n'
            f'\t\t\t\t\t"{(ish_products / "libish.a").as_posix()}",\n'
            '\t\t\t\t\t"-Wl,-force_load",\n'
            f'\t\t\t\t\t"{(ish_products / "libish_emu.a").as_posix()}",\n'
            '\t\t\t\t\t"-Wl,-force_load",\n'
            f'\t\t\t\t\t"{(ish_products / "libfakefs.a").as_posix()}",\n'
            '\t\t\t\t\t"-lsqlite3",\n'
            '\t\t\t\t\t"-lbz2",\n'
            '\t\t\t\t\t"-liconv",\n'
            '\t\t\t\t\t"-lresolv",\n'
            '\t\t\t\t);\n'
            '\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
        )
    return block

def patch_config(s: str, marker: str, next_marker: str | None) -> str:
    start = s.index(marker)
    end = s.index(next_marker, start) if next_marker else s.index('/* End XCBuildConfiguration section */', start)
    return s[:start] + patch_build_settings(s[start:end]) + s[end:]

s = patch_config(s, debug_marker, release_marker)
s = patch_config(s, release_marker, None)

project_file.write_text(s)
PY

echo "Enabled Local Alpine iSH CI adapter in $project_file"
