#!/usr/bin/env bash
set -euo pipefail

ish_dir="${1:-External/ish}"
products_dir="${2:-$PWD/.build/ish-products}"
guest_arch="${IEXA_ISH_GUEST_ARCH:-arm64}"

mkdir -p "$products_dir"

patch_file="$PWD/scripts/ish-signal-waiting-lock.patch"
if [ -f "$patch_file" ]; then
  if git -C "$ish_dir" apply --check "$patch_file"; then
    git -C "$ish_dir" apply "$patch_file"
    echo "Applied iSH signal waiter crash guard"
  elif grep -Fq "waiting_lock != NULL" "$ish_dir/kernel/signal.c"; then
    echo "iSH signal waiter crash guard already present"
  elif ! grep -Fq "trylock(task->waiting_lock)" "$ish_dir/kernel/signal.c"; then
    echo "iSH signal waiter path is already safe for this source version"
  else
    echo "Could not apply iSH signal waiter crash guard" >&2
    git -C "$ish_dir" apply --check "$patch_file" || true
    exit 1
  fi
fi

socket_patch_file="$PWD/scripts/ish-socket-recvfrom-result-length.patch"
if [ -f "$socket_patch_file" ]; then
  if git -C "$ish_dir" apply --check "$socket_patch_file"; then
    git -C "$ish_dir" apply "$socket_patch_file"
    echo "Applied iSH socket nonblock/recv length fixes"
  elif grep -Fq "user_write(buffer_addr, buffer, res)" "$ish_dir/fs/sock.c" &&
       grep -Fq "int guest_flags = fd_getflags(sock)" "$ish_dir/fs/sock.c" &&
       grep -Fq "int guest_flags_rm = fd_getflags(sock)" "$ish_dir/fs/sock.c"; then
    echo "iSH socket nonblock/recv length fixes already present"
  elif grep -Fq "user_write(buffer_addr, buffer, len)" "$ish_dir/fs/sock.c"; then
    python3 - "$ish_dir/fs/sock.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacements = [
    ("bool guest_nonblock = (sock->flags & O_NONBLOCK_) != 0;",
     "int guest_flags = fd_getflags(sock);\n    bool guest_nonblock = (guest_flags >= 0) && (guest_flags & O_NONBLOCK_) != 0;"),
    ('printk("NETDIAG recvfrom-block(pid=%d comm=%s fd=%d real=%d len=%u gflags=%#x hflags=%#x sflags=%#x)\\n",',
     'printk("NETDIAG recvfrom-block(pid=%d comm=%s fd=%d real=%d len=%u gflags=%#x hflags=%#x fdflags=%#x)\\n",'),
    ("host_flags, sock->flags);",
     "host_flags, guest_flags);"),
    ("user_write(buffer_addr, buffer, len)",
     "user_write(buffer_addr, buffer, res)"),
    ("bool guest_nonblock_rm = (sock->flags & O_NONBLOCK_) != 0;",
     "int guest_flags_rm = fd_getflags(sock);\n    bool guest_nonblock_rm = (guest_flags_rm >= 0) && (guest_flags_rm & O_NONBLOCK_) != 0;"),
    ('printk("NETDIAG recvmsg-block(pid=%d comm=%s fd=%d real=%d gflags=%#x hflags=%#x sflags=%#x)\\n",',
     'printk("NETDIAG recvmsg-block(pid=%d comm=%s fd=%d real=%d gflags=%#x hflags=%#x fdflags=%#x)\\n",'),
    ("(unsigned)flags, host_flags_rm, sock->flags);",
     "(unsigned)flags, host_flags_rm, guest_flags_rm);"),
]
changed = False
for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
        changed = True
if not changed:
    raise SystemExit(f"no known iSH socket fix patterns found in {path}")
path.write_text(text)
PY
    echo "Applied iSH socket nonblock/recv length fixes by source rewrite"
  else
    echo "Could not apply iSH socket nonblock/recv length fixes" >&2
    git -C "$ish_dir" apply --check "$socket_patch_file" || true
    exit 1
  fi
fi

if [ "$guest_arch" = "arm64" ]; then
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild is required to build the iSH ARM64 guest libraries for iOS" >&2
    exit 1
  fi
  if ! command -v meson >/dev/null 2>&1; then
    echo "meson is required to build the iSH ARM64 guest libraries" >&2
    exit 1
  fi
  if ! command -v ninja >/dev/null 2>&1; then
    echo "ninja is required to build the iSH ARM64 guest libraries" >&2
    exit 1
  fi

  xcodebuild \
    -project "$ish_dir/iSH.xcodeproj" \
    -target libish \
    -target libish_emu \
    -target libfakefs \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    CONFIGURATION_BUILD_DIR="$products_dir" \
    GUEST_ARCH=arm64 \
    NINJA_TARGETS="libish.a libish_emu.a libfakefs.a" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
else
  xcodebuild \
    -project "$ish_dir/iSH.xcodeproj" \
    -target libish \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    CONFIGURATION_BUILD_DIR="$products_dir" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
fi

bash "$PWD/scripts/local-alpine-ish-compile-probe.sh" "$ish_dir"

meson_dir="$products_dir/meson"
for lib in libish.a libish_emu.a libfakefs.a; do
  if [ ! -s "$products_dir/$lib" ] && [ -s "$meson_dir/$lib" ]; then
    ln -sf "$meson_dir/$lib" "$products_dir/$lib"
  fi
  test -s "$products_dir/$lib"
done

echo "Built iSH static libraries in $products_dir for guest_arch=$guest_arch"
