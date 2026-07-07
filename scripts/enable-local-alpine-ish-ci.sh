#!/usr/bin/env bash
set -euo pipefail

project_file="${1:-Iexa UI.xcodeproj/project.pbxproj}"
ish_products="${2:-$PWD/.build/ish-products}"
ish_dir="${3:-External/ish}"
fakefs_dir="${4:-.build/local-alpine-resources/iexa-alpine-rootfs.fakefs}"

python3 - "$project_file" "$ish_products" "$ish_dir" "$fakefs_dir" <<'PY'
from pathlib import Path
import sys

project_file = Path(sys.argv[1])
ish_products = Path(sys.argv[2]).resolve()
ish_dir = Path(sys.argv[3])
fakefs_dir = Path(sys.argv[4])
s = project_file.read_text()

debug_marker = '\t\t38EB668E2F39CE5C00AED774 /* Debug */ = {\n'
release_marker = '\t\t38EB668F2F39CE5C00AED774 /* Release */ = {\n'
fakefs_file_ref = '38FAE0012FA9000000000001'
fakefs_build_file = '38FAE0022FA9000000000002'
setting_indent = '\t\t\t\t'

def quoted(value: str) -> str:
    return f'"{value}"'

def format_array_setting(key: str, values: list[str]) -> str:
    lines = [f'{setting_indent}{key} = (\n']
    lines.extend(f'{setting_indent}\t{quoted(value)},\n' for value in values)
    lines.append(f'{setting_indent});\n')
    return ''.join(lines)

def insert_setting(block: str, setting: str) -> str:
    for anchor in (
        f'{setting_indent}INFOPLIST_KEY_CFBundleDisplayName = Iexa;\n',
        f'{setting_indent}CURRENT_PROJECT_VERSION = 4;\n',
        f'{setting_indent}IPHONEOS_DEPLOYMENT_TARGET = 18.1;\n',
        f'{setting_indent}LD_RUNPATH_SEARCH_PATHS = (\n',
        f'{setting_indent}MARKETING_VERSION = 3.7;\n',
    ):
        if anchor in block:
            return block.replace(anchor, setting + anchor, 1)
    build_settings_end = '\t\t\t};\n\t\t\tname ='
    if build_settings_end not in block:
        raise RuntimeError('Could not find buildSettings end while enabling Local Alpine iSH runtime')
    return block.replace(build_settings_end, setting + build_settings_end, 1)

def ensure_array_values(block: str, key: str, values: list[str]) -> str:
    start_token = f'{setting_indent}{key} = (\n'
    if start_token not in block:
        return insert_setting(block, format_array_setting(key, values))

    start = block.index(start_token)
    end_token = f'{setting_indent});\n'
    end = block.index(end_token, start)
    body = block[start:end]
    additions = []
    for value in values:
        if value not in body:
            additions.append(f'{setting_indent}\t{quoted(value)},\n')
    if not additions:
        return block
    return block[:end] + ''.join(additions) + block[end:]

def patch_build_settings(block: str) -> str:
    block = ensure_array_values(block, 'GCC_PREPROCESSOR_DEFINITIONS', [
        '$(inherited)',
        'ISH_INTERNAL=1',
        'IEXA_LOCAL_ALPINE_ISH=1',
        'GUEST_ARM64=1',
    ])
    block = ensure_array_values(block, 'OTHER_CFLAGS', [
        '$(inherited)',
        '-DISH_INTERNAL=1',
        '-DIEXA_LOCAL_ALPINE_ISH=1',
        '-DGUEST_ARM64=1',
    ])
    block = ensure_array_values(block, 'HEADER_SEARCH_PATHS', [
        '$(inherited)',
        ish_dir.as_posix(),
        f'{ish_dir.as_posix()}/deps/libarchive/libarchive',
    ])
    block = ensure_array_values(block, 'LIBRARY_SEARCH_PATHS', [
        '$(inherited)',
        ish_products.as_posix(),
    ])
    block = ensure_array_values(block, 'OTHER_LDFLAGS', [
        '$(inherited)',
        (ish_products / 'libish.a').as_posix(),
        (ish_products / 'libish_emu.a').as_posix(),
        (ish_products / 'libfakefs.a').as_posix(),
        '-lsqlite3',
        '-lbz2',
        '-liconv',
        '-lresolv',
    ])
    return block

def patch_config(s: str, marker: str, next_marker: str | None) -> str:
    start = s.index(marker)
    end = s.index(next_marker, start) if next_marker else s.index('/* End XCBuildConfiguration section */', start)
    return s[:start] + patch_build_settings(s[start:end]) + s[end:]

s = patch_config(s, debug_marker, release_marker)
s = patch_config(s, release_marker, None)
if 'IEXA_LOCAL_ALPINE_ISH=1' not in s or '-DIEXA_LOCAL_ALPINE_ISH=1' not in s:
    raise RuntimeError('Failed to enable IEXA_LOCAL_ALPINE_ISH build definitions')
if (ish_products / 'libish.a').as_posix() not in s:
    raise RuntimeError('Failed to add iSH static library link settings')

if fakefs_file_ref not in s:
    s = s.replace(
        '/* Begin PBXFileReference section */\n',
        '/* Begin PBXFileReference section */\n'
        f'\t\t{fakefs_file_ref} /* iexa-alpine-rootfs.fakefs */ = '
        f'{{isa = PBXFileReference; lastKnownFileType = folder; path = "{fakefs_dir.as_posix()}"; sourceTree = SOURCE_ROOT; }};\n',
    )

if fakefs_build_file not in s:
    s = s.replace(
        '/* Begin PBXBuildFile section */\n',
        '/* Begin PBXBuildFile section */\n'
        f'\t\t{fakefs_build_file} /* iexa-alpine-rootfs.fakefs in Resources */ = '
        f'{{isa = PBXBuildFile; fileRef = {fakefs_file_ref} /* iexa-alpine-rootfs.fakefs */; }};\n',
    )

resource_marker = '\t\t38EB667B2F39CE5A00AED774 /* Resources */ = {\n'
resource_start = s.index(resource_marker)
resource_end = s.index('\t\t};\n', resource_start) + len('\t\t};\n')
resource_block = s[resource_start:resource_end]
if fakefs_build_file not in resource_block:
    resource_block = resource_block.replace(
        '\t\t\tfiles = (\n',
        '\t\t\tfiles = (\n'
        f'\t\t\t\t{fakefs_build_file} /* iexa-alpine-rootfs.fakefs in Resources */,\n',
    )
    s = s[:resource_start] + resource_block + s[resource_end:]

project_file.write_text(s)
PY

echo "Enabled Local Alpine iSH CI adapter in $project_file"
