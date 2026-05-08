# Local Alpine iSH Adapter Notes

The Iexa side now looks for these optional native symbols at runtime:

- `iexa_local_alpine_runtime_available`
- `iexa_local_alpine_execute`
- `iexa_local_alpine_free`

They are declared in:

```text
Open UI/Core/Services/LocalAlpineNativeRuntimeABI.h
```

This keeps Open Terminal and provider requests isolated. If the symbols are not
linked, Local Alpine reports unavailable and all existing remote terminal paths
continue to work.

## Required iSH Pieces

The local `C:\Users\Administrator\Desktop\ish-master` checkout is incomplete for
direct build integration because these submodules are empty:

- `deps/libapps`
- `deps/libarchive`
- `deps/linux`

iSH's own project also includes full app lifecycle sources in `libiSHApp`
including `main.m` and `AppDelegate.m`, so Iexa must not link the complete iSH
application target.

The lower-level pieces needed for a headless command runner are:

- `libish.a`
- `libish_emu.a`
- `libfakefs.a`
- fakefs import/export helpers from `tools/fakefs.*`
- boot/exec calls from `kernel/init.h`, `kernel/calls.h`, `kernel/task.h`
- rootfs archive `Open UI/Resources/iexa-alpine-rootfs.tar.gz`

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
2. Boot iSH once with `mount_root`, `become_first_process`,
   `create_some_device_nodes`, `/proc`, and `/dev/pts`.
3. For each command, create a child with `become_new_init_child`.
4. Execute `/bin/sh -lc <command>` in the requested cwd.
5. Capture stdout/stderr through a dedicated pipe or pty.
6. Return a heap-allocated UTF-8 buffer and set `exit_code`.
7. Free returned buffers in `iexa_local_alpine_free`.

Do not use iSH's `main.m`, `AppDelegate.m`, `TerminalViewController.m`, or
Storyboard/UI targets inside Iexa.

## Current Native File

`Open UI/Core/Services/LocalAlpineNativeRuntimeBridge.c` contains a gated native adapter:

- default build: exports the ABI and returns unavailable
- `IEXA_LOCAL_ALPINE_ISH=1`: boots iSH low-level core, mounts fakefs rootfs,
  starts `/bin/sh -lc <command>`, and captures output through a headless TTY

GitHub Actions runs `scripts/prepare-local-alpine-fakefs.sh`,
`scripts/build-local-alpine-ish-ci.sh`, and
`scripts/enable-local-alpine-ish-ci.sh` before archiving the app. The project
file is patched only inside CI, so normal local builds keep the safe stub unless
the iSH adapter is explicitly enabled.
