# Local Alpine iSH Adapter Notes

The Iexa side now looks for these optional native symbols at runtime:

- `iexa_local_alpine_runtime_available`
- `iexa_local_alpine_execute`
- `iexa_local_alpine_free`

They are declared in:

```text
Iexa UI/Core/Services/LocalAlpineNativeRuntimeABI.h
```

This keeps Open Terminal and provider requests isolated. If the symbols are not
linked, Local Alpine reports unavailable and all existing remote terminal paths
continue to work.

## Required iSH ARM64 Pieces

Use the OpenMinis ARM64 fork rather than upstream x86 iSH:

```text
https://github.com/OpenMinis/ish-arm64
```

For local development, a zip checkout at
`C:\Users\Administrator\Desktop\ish-arm64-master` can be staged with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-ish-source.ps1 -SourcePath C:\Users\Administrator\Desktop\ish-arm64-master -Force
```

iSH's own project includes full app lifecycle sources including `main.m` and
`AppDelegate.m`, so Iexa must not link the complete iSH application target.

The lower-level pieces needed for a headless command runner are:

- `libish.a`
- `libish_emu.a`
- `libfakefs.a`
- `GUEST_ARM64=1` / Meson `-Dguest_arch=arm64`
- fakefs import/export helpers from `tools/fakefs.*`
- boot/exec calls from `kernel/init.h`, `kernel/calls.h`, `kernel/task.h`
- aarch64 rootfs archive `Iexa UI/Resources/iexa-alpine-rootfs.tar.gz`

Prepare a complete iSH checkout with:

```bash
bash scripts/prepare-ish-source.sh
```

or on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/prepare-ish-source.ps1
```

This writes to `External/ish`. Do not vendor a partial `ish-master` checkout;
it must include at least `deps/libapps` and `deps/libarchive`.

## Intended Native Flow

The native implementation behind `iexa_local_alpine_execute` should:

1. Use the CI-generated `iexa-alpine-rootfs.fakefs/` bundle directory.
2. Boot iSH ARM64 once with `mount_root`, `become_first_process`,
   `create_some_device_nodes`, `/proc`, and `/dev/pts`.
3. For each command, create a child with `become_new_init_child`.
4. Execute `/bin/sh -lc <command>` in the requested cwd.
5. Capture stdout/stderr through a dedicated pipe or pty.
6. Return a heap-allocated UTF-8 buffer and set `exit_code`.
7. Free returned buffers in `iexa_local_alpine_free`.

Do not use iSH's `main.m`, `AppDelegate.m`, or `TerminalViewController.m`
inside Iexa.

## Current Native File

`Iexa UI/Core/Services/LocalAlpineNativeRuntimeBridge.c` contains a gated native adapter:

- default build: exports the ABI and returns unavailable
- `IEXA_LOCAL_ALPINE_ISH=1` + `GUEST_ARM64=1`: boots the iSH ARM64 low-level
  core, mounts fakefs rootfs, starts `/bin/sh -lc <command>`, and captures
  output through a headless TTY

GitHub Actions runs `scripts/prepare-local-alpine-fakefs.sh`,
`scripts/build-local-alpine-ish-ci.sh`, and
`scripts/enable-local-alpine-ish-ci.sh` before archiving the app. The project
file is patched only inside CI, so normal local builds keep the safe stub unless
the iSH ARM64 adapter is explicitly enabled. `build-local-alpine-ish-ci.sh`
builds the libraries through iSH's Xcode/Meson bridge with `GUEST_ARCH=arm64`.
