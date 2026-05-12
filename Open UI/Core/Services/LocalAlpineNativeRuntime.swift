import Foundation
import Darwin

struct LocalAlpineNativeCommand: Sendable {
    let command: String
    let cwd: String
    let rootArchiveURL: URL
    let workspaceURL: URL
}

struct LocalAlpineNativeRuntime: Sendable {
    static let shared = LocalAlpineNativeRuntime()

    var isLinked: Bool {
        availabilitySymbol != nil && executeSymbol != nil && availabilitySymbol?() == true
    }

    func execute(_ command: LocalAlpineNativeCommand) async -> LocalAlpineCommandResult {
        guard executeSymbol != nil else {
            return unavailableResult(command)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let executeSymbol = Self.shared.executeSymbol else {
                    continuation.resume(returning: Self.shared.unavailableResult(command))
                    return
                }
                var exitCode: Int32 = 126
                let outputPointer = command.command.withCString { commandCString in
                    command.cwd.withCString { cwdCString in
                        command.rootArchiveURL.path.withCString { rootArchiveCString in
                            command.workspaceURL.path.withCString { workspaceCString in
                                executeSymbol(
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
                    Self.shared.releaseSymbol?(outputPointer)
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

    private typealias AvailabilitySymbol = @convention(c) () -> Bool
    private typealias ExecuteSymbol = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafeMutablePointer<Int32>
    ) -> UnsafeMutablePointer<CChar>?
    private typealias ReleaseSymbol = @convention(c) (UnsafeMutablePointer<CChar>) -> Void

    private var availabilitySymbol: AvailabilitySymbol? {
        symbol("iexa_local_alpine_runtime_available", as: AvailabilitySymbol.self)
    }

    private var executeSymbol: ExecuteSymbol? {
        symbol("iexa_local_alpine_execute", as: ExecuteSymbol.self)
    }

    private var releaseSymbol: ReleaseSymbol? {
        symbol("iexa_local_alpine_free", as: ReleaseSymbol.self)
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: type)
    }

    private func unavailableResult(_ command: LocalAlpineNativeCommand) -> LocalAlpineCommandResult {
        LocalAlpineCommandResult(
            command: command.command,
            output: """
            Local Alpine native runtime adapter is present, but no iSH core implementation is linked into this build.

            Rootfs: \(command.rootArchiveURL.lastPathComponent)
            Workspace: \(command.workspaceURL.path)

            Link the iSH core adapter symbols to run apk/gcc/vim/node locally without touching Open Terminal.
            """,
            exitCode: 126
        )
    }
}
