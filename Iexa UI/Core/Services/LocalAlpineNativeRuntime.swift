import Foundation

@_silgen_name("iexa_local_alpine_runtime_available")
private func iexaLocalAlpineRuntimeAvailable() -> Int32

@_silgen_name("iexa_local_alpine_interrupt")
private func iexaLocalAlpineInterrupt() -> Int32

@_silgen_name("iexa_local_alpine_session_start")
private func iexaLocalAlpineSessionStart(
    _ cwd: UnsafePointer<CChar>,
    _ rootArchivePath: UnsafePointer<CChar>,
    _ workspacePath: UnsafePointer<CChar>,
    _ timeZone: UnsafePointer<CChar>
) -> Int32

@_silgen_name("iexa_local_alpine_session_write")
private func iexaLocalAlpineSessionWrite(
    _ sessionID: Int32,
    _ input: UnsafePointer<CChar>
) -> Int32

@_silgen_name("iexa_local_alpine_session_read")
private func iexaLocalAlpineSessionRead(_ sessionID: Int32) -> UnsafeMutablePointer<CChar>?

@_silgen_name("iexa_local_alpine_session_resize")
private func iexaLocalAlpineSessionResize(
    _ sessionID: Int32,
    _ columns: Int32,
    _ rows: Int32
) -> Int32

@_silgen_name("iexa_local_alpine_session_interrupt")
private func iexaLocalAlpineSessionInterrupt(_ sessionID: Int32) -> Int32

@_silgen_name("iexa_local_alpine_session_close")
private func iexaLocalAlpineSessionClose(_ sessionID: Int32) -> Int32

@_silgen_name("iexa_local_alpine_execute")
private func iexaLocalAlpineExecute(
    _ command: UnsafePointer<CChar>,
    _ cwd: UnsafePointer<CChar>,
    _ rootArchivePath: UnsafePointer<CChar>,
    _ workspacePath: UnsafePointer<CChar>,
    _ timeZone: UnsafePointer<CChar>,
    _ exitCode: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("iexa_local_alpine_free")
private func iexaLocalAlpineFree(_ buffer: UnsafeMutablePointer<CChar>)

nonisolated struct LocalAlpineNativeCommand: Sendable {
    let command: String
    let cwd: String
    let rootArchiveURL: URL
    let workspaceURL: URL
    let timeZone: String

    init(
        command: String,
        cwd: String,
        rootArchiveURL: URL,
        workspaceURL: URL,
        timeZone: String = LocalAlpineNativeRuntime.currentPOSIXTimeZone()
    ) {
        self.command = command
        self.cwd = cwd
        self.rootArchiveURL = rootArchiveURL
        self.workspaceURL = workspaceURL
        self.timeZone = timeZone
    }
}

nonisolated struct LocalAlpineNativeRuntime: Sendable {
    static let shared = LocalAlpineNativeRuntime()

    var isLinked: Bool {
        iexaLocalAlpineRuntimeAvailable() == 1
    }

    func interrupt() -> Bool {
        guard isLinked else { return false }
        return iexaLocalAlpineInterrupt() == 1
    }

    func startSession(_ command: LocalAlpineNativeCommand) async -> Int? {
        guard isLinked else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let sessionID = command.cwd.withCString { cwdCString in
                    command.rootArchiveURL.path.withCString { rootArchiveCString in
                        command.workspaceURL.path.withCString { workspaceCString in
                            command.timeZone.withCString { timeZoneCString in
                                iexaLocalAlpineSessionStart(
                                    cwdCString,
                                    rootArchiveCString,
                                    workspaceCString,
                                    timeZoneCString
                                )
                            }
                        }
                    }
                }
                continuation.resume(returning: sessionID > 0 ? Int(sessionID) : nil)
            }
        }
    }

    func writeSessionInput(sessionID: Int, input: String) -> Bool {
        guard isLinked else { return false }
        return input.withCString { inputCString in
            iexaLocalAlpineSessionWrite(Int32(sessionID), inputCString) == 1
        }
    }

    func readSessionOutput(sessionID: Int) -> String {
        guard isLinked else { return "" }
        let outputPointer = iexaLocalAlpineSessionRead(Int32(sessionID))
        let output = outputPointer.map { String(cString: $0) } ?? ""
        if let outputPointer {
            iexaLocalAlpineFree(outputPointer)
        }
        return output
    }

    func resizeSession(sessionID: Int, columns: Int, rows: Int) -> Bool {
        guard isLinked else { return false }
        return iexaLocalAlpineSessionResize(Int32(sessionID), Int32(columns), Int32(rows)) == 1
    }

    func interruptSession(sessionID: Int) -> Bool {
        guard isLinked else { return false }
        return iexaLocalAlpineSessionInterrupt(Int32(sessionID)) == 1
    }

    func closeSession(sessionID: Int) -> Bool {
        guard isLinked else { return false }
        return iexaLocalAlpineSessionClose(Int32(sessionID)) == 1
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
                                command.timeZone.withCString { timeZoneCString in
                                    iexaLocalAlpineExecute(
                                        commandCString,
                                        cwdCString,
                                        rootArchiveCString,
                                        workspaceCString,
                                        timeZoneCString,
                                        &exitCode
                                    )
                                }
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
                        exitCode: Int(exitCode),
                        interactiveRequest: nil
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
            exitCode: 126,
            interactiveRequest: nil
        )
    }

    nonisolated static func currentPOSIXTimeZone() -> String {
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: Date())
        guard offsetSeconds != 0 else { return "UTC0" }

        let absSeconds = abs(offsetSeconds)
        let hours = absSeconds / 3600
        let minutes = (absSeconds % 3600) / 60
        let sign = offsetSeconds >= 0 ? "-" : "+"

        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }
}
