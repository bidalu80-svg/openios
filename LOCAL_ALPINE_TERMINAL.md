# Local Alpine Terminal

This project now has an isolated Local Alpine terminal slot next to the existing Open Terminal server integration.

## What is preserved

- Existing Open Terminal servers still use the Iexa backend APIs.
- Remote terminal IDs are still sent to chat requests only when a remote server is selected.
- The local terminal uses the reserved ID `__iexa_local_alpine__` and is never sent as `terminal_id`.

## Bundled rootfs

The source root archive lives at:

```text
Open UI/Resources/iexa-alpine-rootfs.tar.gz
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
Open UI/Resources/iexa-alpine-rootfs.fakefs/
```

On first local command execution, Iexa copies that bundled fakefs directory into:

```text
Documents/Iexa Alpine/rootfs.fakefs/
```

The native iSH mount path uses `rootfs.fakefs/data` from Documents, so `apk add`
can modify the local rootfs. It does not depend on a server and does not shell
out to unpack archives on device.

## Native runtime bridge

The Swift-side insertion point is:

```text
Open UI/Core/Services/LocalAlpineTerminalService.swift
Open UI/Core/Services/LocalAlpineNativeRuntime.swift
Open UI/Core/Services/LocalAlpineNativeRuntimeABI.h
Open UI/Core/Services/LocalAlpineNativeRuntimeBridge.c
```

The UI and chat state already route Local Alpine separately through:

```text
Open UI/Core/Models/Terminal.swift
Open UI/Features/Terminal/ViewModels/TerminalBrowserViewModel.swift
Open UI/Features/Chat/ViewModels/ChatViewModel.swift
Open UI/Features/Chat/Views/MainChatView.swift
Open UI/Features/Chat/Views/iPadMainChatView.swift
```

`LocalAlpineNativeRuntimeBridge.c` exports the native ABI with a safe default
stub. When compiled with `IEXA_LOCAL_ALPINE_ISH=1` and linked against the iSH
low-level static libraries, it boots the iSH core and runs commands through a
headless TTY capture path. The app's Documents workspace is mounted inside
Alpine at `/mnt/iexa`, so terminal files stay local and visible to Iexa's file
browser.

Do not send `__iexa_local_alpine__` to the backend and do not link iSH's
`main.m`, `AppDelegate.m`, or full UIKit terminal app into Iexa.
