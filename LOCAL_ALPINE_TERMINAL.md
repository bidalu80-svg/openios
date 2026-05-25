# Local Alpine Terminal

This project now has an isolated Local Alpine terminal slot next to the existing Open Terminal server integration.

## What is preserved

- Existing Open Terminal servers still use the Iexa backend APIs.
- Remote terminal IDs are still sent to chat requests only when a remote server is selected.
- The local terminal uses the reserved ID `__iexa_local_alpine__` and is never sent as `terminal_id`.

## Bundled rootfs

The source root archive lives at:

```text
Iexa UI/Resources/iexa-alpine-rootfs.tar.gz
```

It is prepared from Alpine's latest stable x86 minirootfs. The bundled archive
is currently Alpine 3.23.4, matching `alpine-minirootfs-3.23.4-x86.tar.gz`.
The refresh scripts verify the expected SHA256 before accepting the archive.

Prepare or refresh it on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-local-alpine-rootfs.ps1
```

Prepare or refresh it on macOS/Linux:

```bash
bash scripts/prepare-local-alpine-rootfs.sh
```

The GitHub Actions IPA workflow verifies this file, converts it with iSH's
`fakefsify`, and bundles the generated directory resource:

```text
Iexa UI/Resources/iexa-alpine-rootfs.fakefs/
```

On first local command execution, Iexa copies that bundled fakefs directory into:

```text
Documents/Iexa Alpine/rootfs.fakefs/
```

The native iSH mount path uses `rootfs.fakefs/data` from Documents, so `apk add`
can modify the local rootfs. It does not depend on a server and does not shell
out to unpack archives on device.

The Local Alpine file browser has two scopes:

- `工作区` maps to `/mnt/iexa` and stores user/AI-created files.
- `rootfs` browses the Alpine root filesystem itself, including `/bin`, `/etc`,
  `/root`, `/tmp`, and package-managed files.

The `rootfs` menu includes a destructive reset action. If the iSH runtime has
not been booted in the current app session, reset removes the writable
`Documents/Iexa Alpine/rootfs.fakefs/` copy immediately. If the runtime is
already mounted, reset is marked with `.iexa-rootfs-reset-pending` and applied
on the next app launch, leaving `/mnt/iexa` untouched.

The full-screen Local Alpine console treats its cwd as a real Alpine path.
`cd /`, `cd /root`, and `cd /tmp` stay in rootfs; `/mnt/iexa` remains the shared
workspace mount.

## Native runtime bridge

The Swift-side insertion point is:

```text
Iexa UI/Core/Services/LocalAlpineTerminalService.swift
Iexa UI/Core/Services/LocalAlpineNativeRuntime.swift
Iexa UI/Core/Services/LocalAlpineNativeRuntimeABI.h
Iexa UI/Core/Services/LocalAlpineNativeRuntimeBridge.c
```

The UI and chat state already route Local Alpine separately through:

```text
Iexa UI/Core/Models/Terminal.swift
Iexa UI/Features/Terminal/ViewModels/TerminalBrowserViewModel.swift
Iexa UI/Features/Chat/ViewModels/ChatViewModel.swift
Iexa UI/Features/Chat/Views/MainChatView.swift
Iexa UI/Features/Chat/Views/iPadMainChatView.swift
```

`LocalAlpineNativeRuntimeBridge.c` exports the native ABI with a safe default
stub. When compiled with `IEXA_LOCAL_ALPINE_ISH=1` and linked against the iSH
low-level static libraries, it boots the iSH core and runs commands through a
headless TTY capture path. The app's Documents workspace is mounted inside
Alpine at `/mnt/iexa`, so terminal files stay local and visible to Iexa's file
browser.

The native ABI also includes an interactive session surface:

- `iexa_local_alpine_session_start`
- `iexa_local_alpine_session_write`
- `iexa_local_alpine_session_read`
- `iexa_local_alpine_session_resize`
- `iexa_local_alpine_session_interrupt`
- `iexa_local_alpine_session_close`

The full-screen Local Alpine console tries this persistent PTY-backed shell
first. If the native session cannot start, it falls back to the older one-shot
command runner so non-iSH/stub builds remain usable.

Do not send `__iexa_local_alpine__` to the backend and do not link iSH's
`main.m`, `AppDelegate.m`, or full UIKit terminal app into Iexa.
