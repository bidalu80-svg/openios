#!/usr/bin/env python3
import argparse
import io
import tarfile
import urllib.request
from pathlib import PurePosixPath


DEFAULT_BASE_URL = "https://dl-cdn.alpinelinux.org/alpine/v3.19"
DEFAULT_ARCH = "x86"
DEFAULT_REPOS = ("main",)


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def normalize_member_name(name: str) -> str | None:
    normalized = name.lstrip("/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if not normalized or normalized.startswith("."):
        return None
    path = PurePosixPath(normalized)
    if any(part == ".." for part in path.parts):
        return None
    return path.as_posix()


def copy_tar_member(
    source: tarfile.TarFile,
    target: tarfile.TarFile,
    member: tarfile.TarInfo,
    skip_apk_metadata: bool = False,
    skip_names: set[str] | None = None
) -> None:
    name = normalize_member_name(member.name)
    if name is None:
        return
    if skip_names and name in skip_names:
        return
    if skip_apk_metadata and PurePosixPath(name).parts[0].startswith("."):
        return
    member.name = name
    if member.isfile():
        fileobj = source.extractfile(member)
        if fileobj is None:
            return
        target.addfile(member, fileobj)
    else:
        target.addfile(member)


def apk_member_name(member: tarfile.TarInfo) -> str | None:
    name = normalize_member_name(member.name)
    if name is None:
        return None
    if PurePosixPath(name).parts[0].startswith("."):
        return None
    return name


def parse_apkindex(index_bytes: bytes, repo_url: str) -> dict[str, dict[str, str]]:
    records: dict[str, dict[str, str]] = {}
    with tarfile.open(fileobj=io.BytesIO(index_bytes), mode="r:gz") as archive:
        index_file = archive.extractfile("APKINDEX")
        if index_file is None:
            raise RuntimeError(f"APKINDEX missing in {repo_url}")
        raw = index_file.read().decode("utf-8", errors="replace")

    for stanza in raw.split("\n\n"):
        record: dict[str, str] = {}
        for line in stanza.splitlines():
            if len(line) < 3 or line[1] != ":":
                continue
            record[line[0]] = line[2:]
        name = record.get("P")
        version = record.get("V")
        if name and version:
            record["repo_url"] = repo_url
            record["filename"] = f"{name}-{version}.apk"
            records[name] = record
    return records


def package_name_from_dependency(token: str) -> str | None:
    token = token.strip()
    if not token or token.startswith("!"):
        return None
    for marker in ("<=", ">=", "<", ">", "=", "~"):
        if marker in token:
            token = token.split(marker, 1)[0]
            break
    token = token.strip()
    if not token or ":" in token:
        return None
    return token


def dependency_key(token: str) -> str | None:
    token = token.strip()
    if not token or token.startswith("!"):
        return None
    for marker in ("<=", ">=", "<", ">", "=", "~"):
        if marker in token:
            token = token.split(marker, 1)[0]
            break
    return token.strip() or None


def resolve_packages(requested: list[str], indexes: dict[str, dict[str, str]]) -> list[dict[str, str]]:
    resolved: list[dict[str, str]] = []
    visiting: set[str] = set()
    visited: set[str] = set()
    providers: dict[str, str] = {}
    for name, record in indexes.items():
        providers.setdefault(name, name)
        for provided in record.get("p", "").split():
            key = dependency_key(provided)
            if key:
                providers.setdefault(key, name)

    def visit(name: str) -> None:
        name = providers.get(name, name)
        if name in visited:
            return
        if name in visiting:
            return
        record = indexes.get(name)
        if record is None:
            print(f"warning: package not found in APKINDEX, skipping dependency: {name}")
            return
        visiting.add(name)
        for dep in record.get("D", "").split():
            dep_name = package_name_from_dependency(dep)
            if dep_name is None:
                dep_key = dependency_key(dep)
                dep_name = providers.get(dep_key) if dep_key else None
            if dep_name:
                visit(dep_name)
        visiting.remove(name)
        visited.add(name)
        resolved.append(record)

    for package in requested:
        visit(package)

    return resolved


def add_text_file(target: tarfile.TarFile, name: str, content: str, mode: int = 0o644) -> None:
    data = content.encode("utf-8")
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    target.addfile(info, io.BytesIO(data))


def read_text_member(archive: tarfile.TarFile, name: str) -> str:
    member = None
    for candidate in archive.getmembers():
        if normalize_member_name(candidate.name) == name:
            member = candidate
            break
    if member is None:
        return ""
    if not member.isfile():
        return ""
    fileobj = archive.extractfile(member)
    if fileobj is None:
        return ""
    return fileobj.read().decode("utf-8", errors="replace")


def format_apk_record(record: dict[str, str], manifest: list[str]) -> str:
    preferred_order = ["C", "P", "V", "A", "S", "I", "T", "U", "L", "o", "m", "t", "c", "D", "p"]
    lines: list[str] = []
    for key in preferred_order:
        value = record.get(key)
        if value:
            lines.append(f"{key}:{value}")
    for key in sorted(record.keys()):
        if key in preferred_order or key in {"repo_url", "filename"}:
            continue
        value = record.get(key)
        if value:
            lines.append(f"{key}:{value}")

    files_by_dir: dict[str, list[str]] = {}
    dirs: set[str] = set()
    for name in sorted(set(manifest)):
        path = PurePosixPath(name)
        if not path.name:
            continue
        if name.endswith("/"):
            dirs.add(name.rstrip("/"))
            continue
        parent = path.parent.as_posix()
        if parent == ".":
            parent = ""
        files_by_dir.setdefault(parent, []).append(path.name)

    for directory in sorted(dirs | set(files_by_dir.keys())):
        if directory:
            lines.append(f"F:{directory}")
        for filename in sorted(files_by_dir.get(directory, [])):
            lines.append(f"R:{filename}")
    return "\n".join(lines)


def installed_package_names(installed_database: str) -> set[str]:
    names: set[str] = set()
    for stanza in installed_database.split("\n\n"):
        for line in stanza.splitlines():
            if line.startswith("P:"):
                names.add(line[2:])
                break
    return names


def main() -> None:
    parser = argparse.ArgumentParser(description="Overlay selected Alpine APK packages onto a rootfs tarball.")
    parser.add_argument("input_rootfs")
    parser.add_argument("output_rootfs")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--arch", default=DEFAULT_ARCH)
    parser.add_argument("--repo", action="append", default=[])
    parser.add_argument("--packages", nargs="+", required=True)
    args = parser.parse_args()

    repos = args.repo or list(DEFAULT_REPOS)
    indexes: dict[str, dict[str, str]] = {}
    for repo in repos:
        repo_url = f"{args.base_url}/{repo}/{args.arch}"
        index_url = f"{repo_url}/APKINDEX.tar.gz"
        print(f"Fetching {index_url}")
        indexes.update(parse_apkindex(fetch(index_url), repo_url))

    records = resolve_packages(args.packages, indexes)
    print("Preinstalling Alpine packages:")
    for record in records:
        print(f"  - {record['P']} {record['V']}")

    with tarfile.open(args.output_rootfs, mode="w:gz", format=tarfile.PAX_FORMAT) as output:
        with tarfile.open(args.input_rootfs, mode="r:*") as source:
            original_world = read_text_member(source, "etc/apk/world")
            original_installed = read_text_member(source, "lib/apk/db/installed")
            for member in source.getmembers():
                copy_tar_member(
                    source,
                    output,
                    member,
                    skip_names={"etc/apk/world", "lib/apk/db/installed"}
                )

        existing_packages = installed_package_names(original_installed)
        overlay_records_to_install = [record for record in records if record["P"] not in existing_packages]
        manifests: dict[str, list[str]] = {}
        for record in overlay_records_to_install:
            package_url = f"{record['repo_url']}/{record['filename']}"
            print(f"Overlaying {package_url}")
            package_bytes = fetch(package_url)
            manifest: list[str] = []
            with tarfile.open(fileobj=io.BytesIO(package_bytes), mode="r:*") as package:
                for member in package.getmembers():
                    name = apk_member_name(member)
                    if name is not None and member.isdir():
                        manifest.append(f"{name.rstrip('/')}/")
                    elif name is not None and (member.isfile() or member.issym() or member.islnk()):
                        manifest.append(name)
                    copy_tar_member(package, output, member, skip_apk_metadata=True)
            manifests[record["P"]] = manifest

        requested = set(args.packages)
        existing_world = {line.strip() for line in original_world.splitlines() if line.strip()}
        world = "\n".join(sorted(existing_world | requested)) + "\n"
        add_text_file(output, "etc/apk/world", world)

        installed_records = original_installed.strip()
        overlay_records = "\n\n".join(
            format_apk_record(record, manifests.get(record["P"], []))
            for record in overlay_records_to_install
        )
        merged_installed = "\n\n".join(part for part in [installed_records, overlay_records] if part) + "\n"
        add_text_file(output, "lib/apk/db/installed", merged_installed)

    print(f"Wrote enriched rootfs: {args.output_rootfs}")


if __name__ == "__main__":
    main()
