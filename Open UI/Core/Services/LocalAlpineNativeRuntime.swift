import Foundation

@_silgen_name("iexa_local_alpine_runtime_available")
private func iexaLocalAlpineRuntimeAvailable() -> Int32

@_silgen_name("iexa_local_alpine_execute")
private func iexaLocalAlpineExecute(
    _ command: UnsafePointer<CChar>,
    _ cwd: UnsafePointer<CChar>,
    _ rootArchivePath: UnsafePointer<CChar>,
    _ workspacePath: UnsafePointer<CChar>,
    _ exitCode: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("iexa_local_alpine_free")
private func iexaLocalAlpineFree(_ buffer: UnsafeMutablePointer<CChar>)

nonisolated struct LocalAlpineNativeCommand: Sendable {
    let command: String
    let cwd: String
    let rootArchiveURL: URL
    let workspaceURL: URL
}

nonisolated struct LocalAlpineNativeRuntime: Sendable {
    static let shared = LocalAlpineNativeRuntime()

    var isLinked: Bool {
        iexaLocalAlpineRuntimeAvailable() == 1
    }

    func execute(_ command: LocalAlpineNativeCommand) async -> LocalAlpineCommandResult {
        guard isLinked else {
            return unavailableResult(command)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard Self.shared.isLinked else {
                    continuation.resume(returning: Self.shared.unavailableResult(command))
                    return
                }
                var exitCode: Int32 = 126
                let outputPointer = command.command.withCString { commandCString in
                    command.cwd.withCString { cwdCString in
                        command.rootArchiveURL.path.withCString { rootArchiveCString in
                            command.workspaceURL.path.withCString { workspaceCString in
                                iexaLocalAlpineExecute(
                                    commandCString,
                                    cwdCString,
                                    rootArchiveCString,
                                    workspaceCString,
                                    &exitCode
                                )
                            }
                        }
                    }
                }
                let output = outputPointer.map { String(cString: $0) } ?? ""
                if let outputPointer = outputPointer {
                    iexaLocalAlpineFree(outputPointer)
                }
                continuation.resume(
                    returning: LocalAlpineCommandResult(
                        command: command.command,
                        output: output,
                        exitCode: Int(exitCode)
                    )
                )
            }
        }
    }

    private func unavailableResult(_ command: LocalAlpineNativeCommand) -> LocalAlpineCommandResult {
        LocalAlpineCommandResult(
            command: command.command,
            output: """
            Local Alpine native runtime adapter is present, but no iSH core implementation is linked into this build.

            Rootfs: \(command.rootArchiveURL.lastPathComponent)
            Workspace: \(command.workspaceURL.path)
            Terminal path: /mnt/iexa

            Link the iSH core adapter symbols to run apk/gcc/vim/node locally without touching Open Terminal.
            """,
            exitCode: 126
        )
    }
}
