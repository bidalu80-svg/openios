import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import UIKit
import Foundation

private func localAlpinePreviewShouldUseWebView(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    return ["html", "htm", "xhtml", "svg"].contains(url.pathExtension.lowercased())
}

private struct LocalAlpineConsoleContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Local Alpine Terminal Console

struct LocalAlpineTerminalConsoleView: View {
    var onDismiss: () -> Void

    @State private var commandInput = ""
    @State private var entries: [LocalAlpineConsoleEntry] = []
    @State private var isRunning = false
    @State private var pendingInteractiveRequest: LocalAlpineInteractiveRequest?
    @State private var pendingInteractiveInput = ""
    @State private var isCommandFocused = false
    @State private var focusRequestID = UUID()
    @State private var textControlRequest: LocalAlpineTextControlRequest?
    @State private var commandHistory: [String] = []
    @State private var historyCursor: Int?
    @State private var isControlLatched = false
    @State private var isAccessoryBarHidden = false
    @State private var commandInputHeight: CGFloat = 30
    @State private var shellEnvironment: [String: String] = [:]
    @State private var interactiveSessionID: Int?
    @State private var interactiveOutput = ""
    @State private var sessionStartupMessage: String?
    @State private var pollSessionOutput = false
    @State private var isPollingSessionOutput = false
    @State private var streamingCommandSessionID: Int?
    @State private var consoleOutputRevision = 0
    @State private var consoleContentHeight: CGFloat = 0
    @State private var consoleViewportHeight: CGFloat = 0
    @State private var previewFileURL: URL?
    @State private var previewWebURL: WebPreviewURL?

    private let terminalGreen = Color(red: 0.24, green: 0.82, blue: 0.36)
    private let terminalCommandFontSize: CGFloat = 13
    private let terminalOutputFontSize: CGFloat = 12
    @State private var cwd = "/mnt/iexa"
    private let stateMarkerPrefix = "__IEXA_SHELL_STATE__"

    init(
        initialCommand: String? = nil,
        initialCwd: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        _commandInput = State(initialValue: Self.normalizedInitialCommand(initialCommand))
        _cwd = State(initialValue: Self.normalizedInitialCWD(initialCwd))
    }

    private var prompt: String {
        "root@iexa:\(displayCWD)#"
    }

    private var displayCWD: String {
        if cwd == "/root" { return "~" }
        if cwd.hasPrefix("/root/") { return "~/" + String(cwd.dropFirst("/root/".count)) }
        return cwd
    }

    private var usesInteractiveSession: Bool {
        interactiveSessionID != nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal], showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                if let sessionStartupMessage {
                                    Text(sessionStartupMessage)
                                        .font(.system(size: terminalOutputFontSize, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .fixedSize(horizontal: true, vertical: true)
                                        .textSelection(.enabled)
                                }
                                if usesInteractiveSession {
                                    if !interactiveOutput.isEmpty {
                                        Text(interactiveOutput)
                                            .font(.system(size: terminalOutputFontSize, weight: .regular, design: .monospaced))
                                            .foregroundStyle(terminalGreen.opacity(0.88))
                                            .lineLimit(nil)
                                            .fixedSize(horizontal: true, vertical: true)
                                            .textSelection(.enabled)
                                            .id("interactiveOutput")
                                    }
                                } else {
                                    ForEach(entries) { entry in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(entry.prompt) \(entry.command)")
                                                .font(.system(size: terminalCommandFontSize, weight: .regular, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: true, vertical: true)
                                                .textSelection(.enabled)

                                            if !entry.output.isEmpty {
                                                Text(entry.output)
                                                    .font(.system(size: terminalOutputFontSize, weight: .regular, design: .monospaced))
                                                    .foregroundStyle(terminalGreen.opacity(0.88))
                                                    .lineLimit(nil)
                                                    .fixedSize(horizontal: true, vertical: true)
                                                    .textSelection(.enabled)
                                            } else if entry.isRunning {
                                                Text("执行中...")
                                                    .font(.system(size: terminalOutputFontSize, weight: .regular, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.45))
                                            } else if let exitCode = entry.exitCode, exitCode != 0 {
                                                Text("[exit \(exitCode), no output]")
                                                    .font(.system(size: terminalOutputFontSize, weight: .regular, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.45))
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(entry.id)
                                    }
                                }

                                commandLine
                                    .id("commandLine")
                            }
                            .background(
                                GeometryReader { contentGeometry in
                                    Color.clear.preference(
                                        key: LocalAlpineConsoleContentHeightKey.self,
                                        value: contentGeometry.size.height
                                    )
                                }
                            )
                            .frame(
                                minWidth: max(1, geometry.size.width - 8),
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                            .padding(.horizontal, 2)
                            .padding(.top, 0)
                            .padding(.bottom, 18)
                        }
                        .defaultScrollAnchor(.top)
                        .onAppear {
                            consoleViewportHeight = geometry.size.height
                            DispatchQueue.main.async {
                                scrollConsoleToBottomIfNeeded(proxy, availableHeight: geometry.size.height, animated: false)
                            }
                        }
                        .onChange(of: geometry.size.height) { _, value in
                            consoleViewportHeight = value
                        }
                        .onPreferenceChange(LocalAlpineConsoleContentHeightKey.self) { value in
                            let previousHeight = consoleContentHeight
                            consoleContentHeight = value
                            guard value > previousHeight else { return }
                            DispatchQueue.main.async {
                                scrollConsoleToBottomIfNeeded(
                                    proxy,
                                    availableHeight: geometry.size.height,
                                    contentHeight: value,
                                    animated: false
                                )
                            }
                        }
                        .onChange(of: entries.count) { _, _ in
                            scrollConsoleToBottomIfNeeded(proxy, availableHeight: geometry.size.height, animated: true)
                        }
                        .onChange(of: commandInputHeight) { _, _ in
                            scrollConsoleToBottomIfNeeded(proxy, availableHeight: geometry.size.height, animated: true)
                        }
                        .onChange(of: consoleOutputRevision) { _, _ in
                            scrollConsoleToBottomIfNeeded(proxy, availableHeight: geometry.size.height, animated: true)
                        }
                        .onChange(of: interactiveOutput) { _, _ in
                            guard usesInteractiveSession else { return }
                            scrollConsoleToBottomIfNeeded(proxy, availableHeight: geometry.size.height, animated: true)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            refocusCommandLine()
        }
        .task {
            refocusCommandLine()
            await startInteractiveSessionIfPossible()
        }
        .task(id: pollSessionOutput) {
            await pollInteractiveSessionOutput()
        }
        .onDisappear {
            pollSessionOutput = false
            if let streamingCommandSessionID {
                _ = LocalAlpineTerminalService.shared.closeSession(sessionID: streamingCommandSessionID)
            }
            if let interactiveSessionID {
                _ = LocalAlpineTerminalService.shared.closeSession(sessionID: interactiveSessionID)
            }
            streamingCommandSessionID = nil
            interactiveSessionID = nil
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isAccessoryBarHidden && (isCommandFocused || !commandInput.isEmpty) {
                terminalAccessoryBar
            }
        }
        .sheet(item: $pendingInteractiveRequest) { request in
            ActionInputSheet(
                request: ActionInputRequest(
                    title: request.title,
                    message: request.message,
                    placeholder: request.placeholder,
                    defaultValue: request.defaultValue
                ),
                text: $pendingInteractiveInput,
                onConfirm: {
                    let input = pendingInteractiveInput
                    Task { await continueInteractiveCommand(request, input: input) }
                },
                onCancel: {
                    pendingInteractiveRequest = nil
                    pendingInteractiveInput = ""
                    appendSystemOutput("[已取消输入]", exitCode: 124)
                }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .sheet(item: $previewWebURL) { item in
            InAppWebPreviewSheet(url: item.url)
        }
        .quickLookPreview($previewFileURL)
    }

    private var headerBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Color.blue)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")

            Spacer()

            Button {
                clearConsole()
            } label: {
                Image(systemName: "paintbrush")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Color.blue)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清空")
        }
    }

    private func clearConsole() {
        if usesInteractiveSession {
            if let interactiveSessionID {
                _ = LocalAlpineTerminalService.shared.readSessionOutput(sessionID: interactiveSessionID)
            }
            interactiveOutput = ""
            sessionStartupMessage = nil
        } else {
            if let streamingCommandSessionID {
                _ = LocalAlpineTerminalService.shared.closeSession(sessionID: streamingCommandSessionID)
                self.streamingCommandSessionID = nil
            }
            entries.removeAll()
        }
        commandInput = ""
        historyCursor = nil
        isControlLatched = false
        isAccessoryBarHidden = false
        refocusCommandLine()
        Haptics.play(.light)
    }

    private var commandLine: some View {
        LocalAlpineConsoleTextView(
            prompt: "\(prompt) ",
            text: $commandInput,
            isFocused: $isCommandFocused,
            measuredHeight: $commandInputHeight,
            focusRequestID: focusRequestID,
            controlRequest: textControlRequest,
            isEnabled: !isRunning,
            textColor: .white,
            cursorColor: UIColor(red: 0.24, green: 0.82, blue: 0.36, alpha: 1),
            fontSize: terminalCommandFontSize,
            controlLatch: $isControlLatched,
            shouldExecuteOnReturn: { usesInteractiveSession || Self.commandIsCompleteForExecution($0) },
            onReturn: {
                Task { await executeCurrentCommand() }
            },
            onControlCharacter: { character in
                handleControlCharacter(character)
            }
        )
        .frame(minWidth: 24, maxWidth: .infinity)
        .frame(height: commandInputHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private var terminalAccessoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                accessoryButton(title: "隐藏", systemImage: "keyboard.chevron.compact.down") {
                    isCommandFocused = false
                    isControlLatched = false
                    isAccessoryBarHidden = true
                }
                accessoryButton(title: "粘贴", systemImage: "doc.on.clipboard") {
                    pasteIntoCommandLine()
                }
                accessoryTextButton("↵ 回车") {
                    handleReturnAction()
                }
                accessoryTextButton("Esc") {
                    cancelCurrentInput()
                }
                accessoryTextButton("Tab") {
                    sendTextControl(.insert("    "))
                }
                accessoryTextButton("^ Ctrl", active: isControlLatched) {
                    isControlLatched.toggle()
                    Haptics.play(.light)
                    refocusCommandLine()
                }
                accessoryTextButton("^ ↑") {
                    showPreviousHistoryCommand()
                }
                accessoryTextButton("⌄ ↓") {
                    showNextHistoryCommand()
                }
                accessoryTextButton("‹ ←") {
                    sendTextControl(.moveLeft)
                }
                accessoryTextButton("› →") {
                    sendTextControl(.moveRight)
                }
                accessoryTextButton("⊗ C-c") {
                    handleControlC()
                }
                accessoryTextButton("Ⅱ C-z") {
                    handleControlZ()
                }
                accessoryTextButton("⌫ C-d") {
                    handleControlD()
                }
                accessoryTextButton("▣ Files") {
                    runShortcutCommand("ls -la")
                }
                accessoryTextButton("◉ Rootfs") {
                    runShortcutCommand("pwd && ls -la /")
                }
                accessoryTextButton("◇ 自检") {
                    runShortcutCommand(LocalAlpineTerminalService.environmentDiagnosticCommand)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
    }

    private func accessoryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.24, green: 0.82, blue: 0.36))
                .lineLimit(1)
                .frame(height: 24)
                .padding(.horizontal, 7)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func accessoryTextButton(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color(red: 0.24, green: 0.82, blue: 0.36))
                .lineLimit(1)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(active ? Color(red: 0.24, green: 0.82, blue: 0.36) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static func commandIsCompleteForExecution(_ command: String) -> Bool {
        let normalized = command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("\\") {
            return false
        }
        if !pendingHeredocDelimiters(in: normalized).isEmpty {
            return false
        }
        let controlText = shellControlTextExcludingHeredocBodies(in: normalized)
        if hasUnclosedShellQuote(in: controlText)
            || hasUnclosedShellGrouping(in: controlText)
            || hasIncompleteShellCompoundSyntax(in: controlText) {
            return false
        }
        return true
    }

    private static func hasUnclosedShellQuote(in command: String) -> Bool {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        for character in command {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = doubleQuoted || !singleQuoted
                continue
            }
            if character == "'", !doubleQuoted {
                singleQuoted.toggle()
            } else if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
            }
        }
        return singleQuoted || doubleQuoted || escaped
    }

    private static func hasUnclosedShellGrouping(in command: String) -> Bool {
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var stack: [Character] = []
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        for character in command {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = doubleQuoted || !singleQuoted
                continue
            }
            if character == "'", !doubleQuoted {
                singleQuoted.toggle()
                continue
            }
            if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
                continue
            }
            guard !singleQuoted && !doubleQuoted else { continue }
            if pairs.keys.contains(character) {
                stack.append(character)
            } else if let last = stack.last, pairs[last] == character {
                stack.removeLast()
            }
        }
        return !stack.isEmpty
    }

    private static func pendingHeredocDelimiters(in command: String) -> [String] {
        var pending: [String] = []
        let pattern = #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_.-]*)['"]?"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for rawLine in command.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = pending.last, line == last {
                pending.removeLast()
                continue
            }
            guard let regex else { continue }
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            for match in matches where match.numberOfRanges >= 2 {
                let delimiter = nsLine.substring(with: match.range(at: 1))
                if !delimiter.isEmpty {
                    pending.append(delimiter)
                }
            }
        }
        return pending
    }

    private static func shellControlTextExcludingHeredocBodies(in command: String) -> String {
        var result: [String] = []
        var pending: [String] = []
        let pattern = #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_.-]*)['"]?"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for rawLine in command.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = pending.last {
                if line == last {
                    pending.removeLast()
                    result.append(rawLine)
                }
                continue
            }

            result.append(rawLine)
            guard let regex else { continue }
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            for match in matches where match.numberOfRanges >= 2 {
                let delimiter = nsLine.substring(with: match.range(at: 1))
                if !delimiter.isEmpty {
                    pending.append(delimiter)
                }
            }
        }

        return result.joined(separator: "\n")
    }

    private static func hasIncompleteShellCompoundSyntax(in command: String) -> Bool {
        var ifDepth = 0
        var loopDepth = 0
        var caseDepth = 0
        let tokenPattern = #"(?m)(^|[;&|]\s*)\s*(if|for|while|until|case)\b|\b(fi|done|esac)\b"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return false }
        let syntaxText = shellTextForCompoundSyntax(command)
        let nsCommand = syntaxText as NSString
        let matches = regex.matches(in: syntaxText, range: NSRange(location: 0, length: nsCommand.length))
        for match in matches {
            let tokenRange = (2..<match.numberOfRanges)
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let tokenRange else { continue }
            let token = nsCommand.substring(with: tokenRange).lowercased()
            switch token {
            case "if":
                ifDepth += 1
            case "fi":
                ifDepth = max(0, ifDepth - 1)
            case "for", "while", "until":
                loopDepth += 1
            case "done":
                loopDepth = max(0, loopDepth - 1)
            case "case":
                caseDepth += 1
            case "esac":
                caseDepth = max(0, caseDepth - 1)
            default:
                break
            }
        }
        return ifDepth > 0 || loopDepth > 0 || caseDepth > 0
    }

    private static func shellTextForCompoundSyntax(_ command: String) -> String {
        var result = ""
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var inComment = false

        for character in command {
            if inComment {
                if character == "\n" {
                    inComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                continue
            }
            if escaped {
                escaped = false
                result.append(singleQuoted || doubleQuoted ? " " : String(character))
                continue
            }
            if character == "\\" {
                escaped = doubleQuoted || !singleQuoted
                result.append(singleQuoted || doubleQuoted ? " " : "\\")
                continue
            }
            if character == "'", !doubleQuoted {
                singleQuoted.toggle()
                result.append(" ")
                continue
            }
            if character == "\"", !singleQuoted {
                doubleQuoted.toggle()
                result.append(" ")
                continue
            }
            if character == "#", !singleQuoted && !doubleQuoted {
                inComment = true
                result.append(" ")
                continue
            }
            result.append(singleQuoted || doubleQuoted ? " " : String(character))
        }

        return result
    }

    private func handleReturnAction() {
        if usesInteractiveSession {
            sendInteractiveInput(commandInput + "\n")
            if !commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commandHistory.append(commandInput)
            }
            commandInput = ""
            historyCursor = nil
            isControlLatched = false
            refocusCommandLine()
            return
        }
        let trimmed = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refocusCommandLine()
            return
        }
        if Self.commandIsCompleteForExecution(commandInput) {
            Task { await executeCurrentCommand() }
        } else {
            sendTextControl(.insert("\n"))
        }
    }

    private func executeCurrentCommand() async {
        let command = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesInteractiveSession {
            sendInteractiveInput(commandInput + "\n")
            if !command.isEmpty {
                commandHistory.append(commandInput)
            }
            commandInput = ""
            historyCursor = nil
            isControlLatched = false
            refocusCommandLine()
            return
        }
        guard !command.isEmpty, !isRunning else { return }

        commandInput = ""
        commandHistory.append(command)
        historyCursor = nil
        isControlLatched = false
        isRunning = true
        Haptics.play(.light)

        entries.append(LocalAlpineConsoleEntry(prompt: prompt, command: command, output: "", exitCode: nil, isRunning: true))
        let result = await LocalAlpineTerminalService.shared.executeStreaming(
            command: stateTrackingCommand(for: command),
            cwd: cwd,
            cwdIsRuntimePath: true,
            onSessionStart: { sessionID in
                streamingCommandSessionID = sessionID
            },
            onOutput: { output in
                updateRunningEntryOutput(output)
            }
        )
        applyResult(result)
        updateShellState(from: result)
    }

    private func continueInteractiveCommand(_ request: LocalAlpineInteractiveRequest, input: String) async {
        pendingInteractiveRequest = nil
        pendingInteractiveInput = ""
        isRunning = true

        let result = await LocalAlpineTerminalService.shared.execute(
            command: stateTrackingCommand(for: request.command),
            cwd: request.cwd,
            stdinInput: input,
            cwdIsRuntimePath: true
        )
        applyResult(result)
        updateShellState(from: result)
    }

    private func applyResult(_ result: LocalAlpineCommandResult) {
        if let index = entries.indices.last {
            entries[index].output = visibleOutput(for: result)
            entries[index].exitCode = result.exitCode
            entries[index].isRunning = result.interactiveRequest != nil
        }
        consoleOutputRevision += 1
        streamingCommandSessionID = nil

        if let request = result.interactiveRequest {
            pendingInteractiveInput = request.defaultValue
            pendingInteractiveRequest = request
            isRunning = false
            handleOpenRequests(result.openRequests)
            return
        }

        handleOpenRequests(result.openRequests)
        isRunning = false
        refocusCommandLine()
    }

    private func handleOpenRequests(_ requests: [LocalAlpineOpenRequest]) {
        guard !requests.isEmpty else { return }
        for request in requests {
            if let url = request.webURL {
                previewWebURL = WebPreviewURL(url: url)
                continue
            }
            Task {
                do {
                    let url = try await LocalAlpineTerminalService.shared.materializePreviewURL(for: request)
                    await MainActor.run {
                        if localAlpinePreviewShouldUseWebView(url) {
                            previewWebURL = WebPreviewURL(url: url)
                        } else {
                            previewFileURL = url
                        }
                    }
                } catch {
                    await MainActor.run {
                        appendSystemOutput("预览失败：\(error.localizedDescription)", exitCode: nil)
                    }
                }
            }
        }
    }

    private func appendSystemOutput(_ output: String, exitCode: Int?) {
        if let index = entries.indices.last {
            entries[index].output += entries[index].output.isEmpty ? output : "\n\(output)"
            entries[index].exitCode = exitCode
            entries[index].isRunning = false
        }
        consoleOutputRevision += 1
        isRunning = false
        refocusCommandLine()
    }

    private func appendRunningNotice(_ output: String) {
        if let index = entries.indices.last {
            entries[index].output += entries[index].output.isEmpty ? output : "\n\(output)"
        }
        consoleOutputRevision += 1
    }

    private func updateRunningEntryOutput(_ output: String) {
        if let index = entries.indices.last {
            entries[index].output = output
            entries[index].isRunning = true
        }
        consoleOutputRevision += 1
    }

    private func visibleOutput(for result: LocalAlpineCommandResult) -> String {
        let cleaned = outputWithoutStateMarker(result.output)
        let output = cleaned.trimmingCharacters(in: .newlines)
        guard output.isEmpty else { return cleaned }
        if result.exitCode == 0 {
            return ""
        }
        if let exitCode = result.exitCode {
            return "[exit \(exitCode), no output]"
        }
        return "[command finished without output]"
    }

    private func refocusCommandLine() {
        isAccessoryBarHidden = false
        isCommandFocused = false
        focusRequestID = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isCommandFocused = true
            focusRequestID = UUID()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isCommandFocused = true
            focusRequestID = UUID()
        }
    }

    private func pasteIntoCommandLine() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else {
            refocusCommandLine()
            return
        }
        let inlinePaste = sanitizedInlineCommandText(pasted)
        guard !inlinePaste.isEmpty else {
            refocusCommandLine()
            return
        }
        isControlLatched = false
        sendTextControl(.insert(inlinePaste))
    }

    private func sanitizedInlineCommandText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func cancelCurrentInput() {
        if usesInteractiveSession {
            sendInteractiveInput("\u{1b}")
            isControlLatched = false
            refocusCommandLine()
            return
        }
        commandInput = ""
        historyCursor = nil
        isControlLatched = false
        refocusCommandLine()
    }

    private func sendTextControl(_ action: LocalAlpineTextControlAction) {
        isControlLatched = false
        isAccessoryBarHidden = false
        textControlRequest = LocalAlpineTextControlRequest(action: action)
        isCommandFocused = true
        focusRequestID = UUID()
    }

    private func handleControlCharacter(_ character: Character) {
        switch String(character).lowercased() {
        case "a":
            sendTextControl(.moveToStart)
        case "c":
            handleControlC()
        case "d":
            handleControlD()
        case "e":
            sendTextControl(.moveToEnd)
        case "u":
            cancelCurrentInput()
        case "z":
            handleControlZ()
        default:
            isControlLatched = false
            refocusCommandLine()
        }
    }

    private func showPreviousHistoryCommand() {
        guard !commandHistory.isEmpty else {
            refocusCommandLine()
            return
        }
        let nextIndex: Int
        if let historyCursor {
            nextIndex = max(0, historyCursor - 1)
        } else {
            nextIndex = commandHistory.count - 1
        }
        historyCursor = nextIndex
        commandInput = commandHistory[nextIndex]
        sendTextControl(.moveToEnd)
    }

    private func showNextHistoryCommand() {
        guard !commandHistory.isEmpty else {
            refocusCommandLine()
            return
        }
        guard let historyCursor else {
            commandInput = ""
            refocusCommandLine()
            return
        }
        let nextIndex = historyCursor + 1
        if nextIndex >= commandHistory.count {
            self.historyCursor = nil
            commandInput = ""
        } else {
            self.historyCursor = nextIndex
            commandInput = commandHistory[nextIndex]
        }
        sendTextControl(.moveToEnd)
    }

    private func handleControlC() {
        isControlLatched = false
        if let interactiveSessionID {
            let sent = LocalAlpineTerminalService.shared.interruptSession(sessionID: interactiveSessionID)
            if !sent {
                interactiveOutput += "\r\n[Ctrl-C 发送失败]\r\n"
            }
            commandInput = ""
            refocusCommandLine()
        } else if let streamingCommandSessionID {
            let sent = LocalAlpineTerminalService.shared.interruptSession(sessionID: streamingCommandSessionID)
            appendRunningNotice(sent ? "^C" : "[Ctrl-C 发送失败；当前命令会在返回或超时后结束]")
        } else if isRunning {
            let sent = LocalAlpineTerminalService.shared.interruptRunningCommand()
            appendRunningNotice(sent ? "^C" : "[Ctrl-C 发送失败；当前命令会在返回或超时后结束]")
        } else if !commandInput.isEmpty {
            entries.append(LocalAlpineConsoleEntry(prompt: prompt, command: commandInput, output: "^C", exitCode: 130, isRunning: false))
            commandInput = ""
            historyCursor = nil
            refocusCommandLine()
        } else {
            entries.append(LocalAlpineConsoleEntry(prompt: prompt, command: "^C", output: "", exitCode: 130, isRunning: false))
            refocusCommandLine()
        }
        Haptics.play(.light)
    }

    private func handleControlZ() {
        isControlLatched = false
        if isRunning {
            appendRunningNotice("[Ctrl-Z 暂停在当前本地执行模式不可用；请用 C-c 中断]")
        }
        refocusCommandLine()
        Haptics.play(.light)
    }

    private func handleControlD() {
        isControlLatched = false
        if usesInteractiveSession, commandInput.isEmpty {
            sendInteractiveInput("\u{4}")
            Haptics.play(.light)
            return
        }
        guard !commandInput.isEmpty else {
            refocusCommandLine()
            Haptics.play(.light)
            return
        }
        sendTextControl(.deleteForward)
        Haptics.play(.light)
    }

    private func runShortcutCommand(_ command: String) {
        guard !isRunning else { return }
        if usesInteractiveSession {
            sendInteractiveInput(command + "\n")
            commandHistory.append(command)
            return
        }
        commandInput = command
        Task { await executeCurrentCommand() }
    }

    private func startInteractiveSessionIfPossible() async {
        guard interactiveSessionID == nil else { return }
        let result = await LocalAlpineTerminalService.shared.startInteractiveSession(
            cwd: cwd,
            cwdIsRuntimePath: true
        )
        if let sessionID = result.sessionID {
            interactiveSessionID = sessionID
            sessionStartupMessage = nil
            pollSessionOutput = true
            _ = LocalAlpineTerminalService.shared.resizeSession(sessionID: sessionID, columns: 120, rows: 40)
        } else if let message = result.message {
            sessionStartupMessage = "\(message)\n已回退到一次性命令执行模式。"
        }
        refocusCommandLine()
    }

    private func pollInteractiveSessionOutput() async {
        guard pollSessionOutput else { return }
        guard !isPollingSessionOutput else { return }
        isPollingSessionOutput = true
        defer { isPollingSessionOutput = false }
        while pollSessionOutput {
            if let sessionID = interactiveSessionID {
                let output = LocalAlpineTerminalService.shared.readSessionOutput(sessionID: sessionID)
                if !output.isEmpty {
                    appendInteractiveOutput(output, sessionID: sessionID)
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func appendInteractiveOutput(_ output: String, sessionID: Int) {
        var sanitized = output
        while let range = sanitized.range(of: "\u{1B}[6n") {
            sanitized.removeSubrange(range)
            let cursor = interactiveCursorPosition()
            _ = LocalAlpineTerminalService.shared.writeSessionInput(
                sessionID: sessionID,
                input: "\u{1B}[\(cursor.row);\(cursor.column)R"
            )
        }
        let parsed = LocalAlpineOpenMarkerParser.extract(from: sanitized)
        handleOpenRequests(parsed.requests)
        sanitized = Self.sanitizedTerminalOutput(parsed.cleaned)

        if sanitized.isEmpty { return }
        interactiveOutput += sanitized
    }

    private func scrollConsoleToBottomIfNeeded(
        _ proxy: ScrollViewProxy,
        availableHeight: CGFloat,
        contentHeight: CGFloat? = nil,
        animated: Bool
    ) {
        let viewportHeight = max(1, availableHeight > 0 ? availableHeight : consoleViewportHeight)
        let measuredContentHeight = contentHeight ?? consoleContentHeight
        let shouldFollowBottom = measuredContentHeight > viewportHeight + 18
        guard shouldFollowBottom else { return }

        let action = {
            proxy.scrollTo("commandLine", anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.12), action)
        } else {
            action()
        }
    }

    private static func sanitizedTerminalOutput(_ output: String) -> String {
        let escape = "\u{1B}"
        let patterns = [
            "\(escape)\\[\\?[0-9;]*[A-Za-z]",
            "\(escape)\\[[0-9;]*[A-Za-z]"
        ]
        return patterns.reduce(output) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let currentRange = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, range: currentRange, withTemplate: "")
        }
        .replacingOccurrences(of: "\u{0007}", with: "")
        .replacingOccurrences(of: "\u{0008}", with: "")
    }

    private func interactiveCursorPosition() -> (row: Int, column: Int) {
        let normalized = interactiveOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let row = max(1, lines.count)
        let column = max(1, (lines.last?.count ?? 0) + 1)
        return (row, column)
    }

    private func sendInteractiveInput(_ input: String) {
        guard let interactiveSessionID else { return }
        _ = LocalAlpineTerminalService.shared.writeSessionInput(
            sessionID: interactiveSessionID,
            input: input
        )
    }

    private static func normalizedRuntimeCWD(_ rawPath: String) -> String {
        var path = rawPath.replacingOccurrences(of: "\\", with: "/")
        if path == "~" {
            path = "/root"
        } else if path.hasPrefix("~/") {
            path = "/root/" + String(path.dropFirst(2))
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func stateTrackingCommand(for command: String) -> String {
        if command.contains(stateMarkerPrefix) {
            return command
        }
        let envExports = shellEnvironment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellSingleQuoted($0.value))" }
            .joined(separator: "\n")
        let prefix = envExports.isEmpty ? "" : "\(envExports)\n"
        return """
        \(prefix){
        \(command)
        }
        __iexa_status=$?
        printf '\\n\(stateMarkerPrefix)PWD=%s\\tPATH=%s\\tHOME=%s\\n' "$PWD" "${PATH:-}" "${HOME:-}"
        exit "$__iexa_status"
        """
    }

    private func updateShellState(from result: LocalAlpineCommandResult) {
        guard result.interactiveRequest == nil else { return }
        guard let line = result.output
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(stateMarkerPrefix) }) else { return }

        let payload = String(line.dropFirst(stateMarkerPrefix.count))
        for part in payload.split(separator: "\t", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = String(pieces[0])
            let value = String(pieces[1])
            switch key {
            case "PWD":
                cwd = Self.normalizedRuntimeCWD(value)
            case "PATH", "HOME":
                shellEnvironment[key] = value
            default:
                break
            }
        }
    }

    private func outputWithoutStateMarker(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(stateMarkerPrefix) }
            .joined(separator: "\n")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func normalizedInitialCommand(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func normalizedInitialCWD(_ value: String?) -> String {
        var trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/") ?? ""
        guard !trimmed.isEmpty else { return "/mnt/iexa" }

        if trimmed == "~" {
            return "/root"
        }
        if trimmed.hasPrefix("~/") {
            return "/root/" + String(trimmed.dropFirst(2))
        }
        if trimmed.hasPrefix("/") {
            return Self.normalizedRuntimeCWD(trimmed)
        }
        while trimmed.hasPrefix("./") {
            trimmed.removeFirst(2)
        }
        let relative = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/mnt/iexa" : "/mnt/iexa/\(relative)"
    }
}

private struct LocalAlpineConsoleEntry: Identifiable {
    let id = UUID()
    let prompt: String
    let command: String
    var output: String
    var exitCode: Int?
    var isRunning: Bool
}

private struct LocalAlpineTextControlRequest: Equatable {
    let id = UUID()
    let action: LocalAlpineTextControlAction
}

private enum LocalAlpineTextControlAction: Equatable {
    case insert(String)
    case moveLeft
    case moveRight
    case moveToStart
    case moveToEnd
    case deleteBackward
    case deleteForward
}

private struct LocalAlpineConsoleTextView: UIViewRepresentable {
    var prompt: String
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    var focusRequestID: UUID
    var controlRequest: LocalAlpineTextControlRequest?
    var isEnabled: Bool
    var textColor: UIColor
    var cursorColor: UIColor
    var fontSize: CGFloat
    @Binding var controlLatch: Bool
    var shouldExecuteOnReturn: (String) -> Bool
    var onReturn: () -> Void
    var onControlCharacter: (Character) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = LocalAlpineConsoleInputView()
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = textColor
        view.tintColor = cursorColor
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.textContainer.heightTracksTextView = false
        view.textContainer.lineBreakMode = .byCharWrapping
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.alwaysBounceHorizontal = false
        view.clipsToBounds = false
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.returnKeyType = .default
        view.keyboardAppearance = .dark
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.prompt = prompt
        context.coordinator.shouldExecuteOnReturn = shouldExecuteOnReturn
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let displayedText = prompt + text
        let previousCommandCursorOffset = context.coordinator.commandCursorOffset(in: view)
        if view.text != displayedText {
            view.text = displayedText
            context.coordinator.setCommandCursorOffset(previousCommandCursorOffset ?? text.utf16.count, in: view)
        }
        view.isEditable = isEnabled
        view.isSelectable = isEnabled
        view.textColor = textColor
        view.tintColor = cursorColor
        if let controlRequest,
           context.coordinator.lastControlRequestID != controlRequest.id {
            context.coordinator.lastControlRequestID = controlRequest.id
            context.coordinator.apply(controlRequest.action, to: view)
            text = context.coordinator.commandText(in: view)
        }
        context.coordinator.updateHeight(for: view)

        let shouldFocus = isEnabled && (isFocused || context.coordinator.lastFocusRequestID != focusRequestID)
        if shouldFocus, !view.isFirstResponder {
            DispatchQueue.main.async {
                view.becomeFirstResponder()
            }
        } else if (!isFocused || !isEnabled), view.isFirstResponder {
            DispatchQueue.main.async {
                view.resignFirstResponder()
            }
        }
        context.coordinator.lastFocusRequestID = focusRequestID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            prompt: prompt,
            text: $text,
            isFocused: $isFocused,
            measuredHeight: $measuredHeight,
            controlLatch: $controlLatch,
            shouldExecuteOnReturn: shouldExecuteOnReturn,
            onReturn: onReturn,
            onControlCharacter: onControlCharacter
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var prompt: String
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var measuredHeight: CGFloat
        @Binding var controlLatch: Bool
        var shouldExecuteOnReturn: (String) -> Bool
        var onReturn: () -> Void
        var onControlCharacter: (Character) -> Void
        var lastFocusRequestID: UUID?
        var lastControlRequestID: UUID?

        init(
            prompt: String,
            text: Binding<String>,
            isFocused: Binding<Bool>,
            measuredHeight: Binding<CGFloat>,
            controlLatch: Binding<Bool>,
            shouldExecuteOnReturn: @escaping (String) -> Bool,
            onReturn: @escaping () -> Void,
            onControlCharacter: @escaping (Character) -> Void
        ) {
            self.prompt = prompt
            _text = text
            _isFocused = isFocused
            _measuredHeight = measuredHeight
            _controlLatch = controlLatch
            self.shouldExecuteOnReturn = shouldExecuteOnReturn
            self.onReturn = onReturn
            self.onControlCharacter = onControlCharacter
        }

        func textViewDidChange(_ textView: UITextView) {
            guard (textView.text ?? "").hasPrefix(prompt) else {
                textView.text = prompt + text
                setCommandCursorOffset(text.utf16.count, in: textView)
                updateHeight(for: textView)
                return
            }
            text = commandText(in: textView)
            if fullCursorOffset(in: textView) < promptUTF16Length {
                setCommandCursorOffset(0, in: textView)
            }
            updateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
            if fullCursorOffset(in: textView) < promptUTF16Length {
                setCommandCursorOffset(0, in: textView)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused = false
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            if let controlCharacter = controlCharacter(from: string) {
                controlLatch = false
                onControlCharacter(controlCharacter)
                return false
            }
            if controlLatch {
                controlLatch = false
            }

            if string == "\n" || string == "\r" || string == "\r\n" {
                let currentCommand = commandText(in: textView)
                guard !currentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                if shouldExecuteOnReturn(currentCommand) {
                    onReturn()
                } else {
                    replaceCharacters(in: textView, range: range, with: "\n")
                }
                return false
            }

            let sanitized = Self.sanitizedPastedText(string)
            guard sanitized == string else {
                replaceCharacters(in: textView, range: range, with: sanitized)
                return false
            }
            guard isEditableCommandRange(range) else {
                replaceCharacters(in: textView, range: range, with: string)
                return false
            }
            return true
        }

        func apply(_ action: LocalAlpineTextControlAction, to view: UITextView) {
            if !view.isFirstResponder {
                view.becomeFirstResponder()
            }

            switch action {
            case .insert(let value):
                let sanitized = Self.sanitizedPastedText(value)
                if !sanitized.isEmpty {
                    replaceCharacters(in: view, range: view.selectedNSRange, with: sanitized)
                }
            case .moveLeft:
                moveCursor(in: view, offset: -1)
            case .moveRight:
                moveCursor(in: view, offset: 1)
            case .moveToStart:
                let start = view.beginningOfDocument
                view.selectedTextRange = view.textRange(from: start, to: start)
            case .moveToEnd:
                let end = view.endOfDocument
                view.selectedTextRange = view.textRange(from: end, to: end)
            case .deleteBackward:
                deleteBackward(in: view)
            case .deleteForward:
                deleteForward(in: view)
            }
            text = commandText(in: view)
            updateHeight(for: view)
        }

        private func controlCharacter(from string: String) -> Character? {
            guard controlLatch, string.count == 1, let scalar = string.unicodeScalars.first else { return nil }
            let value = scalar.value
            guard (65...90).contains(value) || (97...122).contains(value) else { return nil }
            return Character(String(scalar).lowercased())
        }

        private static func sanitizedPastedText(_ text: String) -> String {
            text
                .replacingOccurrences(
                    of: #"\\[ \t]*\r?\n[ \t]*"#,
                    with: "\\\n",
                    options: .regularExpression
                )
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }

        private func replaceCharacters(in view: UITextView, range: NSRange, with replacement: String) {
            guard let currentText = view.text,
                  let swiftRange = Range(editableCommandRange(from: range, in: view), in: currentText) else {
                setCommandCursorOffset(text.utf16.count, in: view)
                updateHeight(for: view)
                return
            }

            view.text = currentText.replacingCharacters(in: swiftRange, with: replacement)
            let cursorOffset = editableCommandRange(from: range, in: view).location + replacement.utf16.count
            if let position = view.position(from: view.beginningOfDocument, offset: cursorOffset) {
                view.selectedTextRange = view.textRange(from: position, to: position)
            }
            text = commandText(in: view)
            updateHeight(for: view)
        }

        func updateHeight(for view: UITextView) {
            let width = max(24, view.bounds.width)
            let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let maxHeight: CGFloat = 260
            let contentHeight = ceil(view.sizeThatFits(fittingSize).height)
            let needsInternalScroll = contentHeight > maxHeight + 0.5
            if view.isScrollEnabled != needsInternalScroll {
                view.isScrollEnabled = needsInternalScroll
            }
            view.showsVerticalScrollIndicator = needsInternalScroll
            view.alwaysBounceVertical = needsInternalScroll

            let height = max(30, min(maxHeight, contentHeight))
            if abs(measuredHeight - height) > 0.5 {
                DispatchQueue.main.async {
                    self.measuredHeight = height
                }
            }
            if needsInternalScroll {
                DispatchQueue.main.async {
                    view.scrollRangeToVisible(view.selectedNSRange)
                }
            }
        }

        private func deleteForward(in view: UITextView) {
            guard let selectedRange = view.selectedTextRange else { return }
            if !selectedRange.isEmpty {
                replaceCharacters(in: view, range: view.selectedNSRange, with: "")
                updateHeight(for: view)
                return
            }
            if fullCursorOffset(in: view) < promptUTF16Length {
                setCommandCursorOffset(0, in: view)
            }
            guard let selectedRange = view.selectedTextRange else { return }
            guard let nextPosition = view.position(from: selectedRange.start, offset: 1),
                  let deleteRange = view.textRange(from: selectedRange.start, to: nextPosition) else { return }
            view.replace(deleteRange, withText: "")
            text = commandText(in: view)
            if fullCursorOffset(in: view) < promptUTF16Length {
                setCommandCursorOffset(0, in: view)
            }
            updateHeight(for: view)
        }

        private func deleteBackward(in view: UITextView) {
            if let range = view.selectedTextRange, !range.isEmpty {
                replaceCharacters(in: view, range: view.selectedNSRange, with: "")
                return
            }
            guard fullCursorOffset(in: view) > promptUTF16Length else {
                setCommandCursorOffset(0, in: view)
                return
            }
            view.deleteBackward()
            text = commandText(in: view)
            updateHeight(for: view)
        }

        private func moveCursor(in view: UITextView, offset: Int) {
            guard let range = view.selectedTextRange,
                  let rawPosition = view.position(from: range.start, offset: offset) else { return }
            let rawOffset = view.offset(from: view.beginningOfDocument, to: rawPosition)
            let clampedOffset = max(promptUTF16Length, rawOffset)
            guard let position = view.position(from: view.beginningOfDocument, offset: clampedOffset) else { return }
            view.selectedTextRange = view.textRange(from: position, to: position)
        }

        func commandText(in view: UITextView) -> String {
            let fullText = view.text ?? ""
            guard fullText.hasPrefix(prompt) else { return text }
            return String(fullText.dropFirst(prompt.count))
        }

        func commandCursorOffset(in view: UITextView) -> Int? {
            guard let range = view.selectedTextRange else { return nil }
            return max(0, view.offset(from: view.beginningOfDocument, to: range.start) - promptUTF16Length)
        }

        func setCommandCursorOffset(_ commandOffset: Int, in view: UITextView) {
            let fullLength = (view.text ?? "").utf16.count
            let offset = min(max(promptUTF16Length, promptUTF16Length + commandOffset), fullLength)
            guard let position = view.position(from: view.beginningOfDocument, offset: offset) else { return }
            view.selectedTextRange = view.textRange(from: position, to: position)
        }

        private var promptUTF16Length: Int {
            (prompt as NSString).length
        }

        private func fullCursorOffset(in view: UITextView) -> Int {
            guard let range = view.selectedTextRange else { return promptUTF16Length }
            return view.offset(from: view.beginningOfDocument, to: range.start)
        }

        private func isEditableCommandRange(_ range: NSRange) -> Bool {
            range.location >= promptUTF16Length
        }

        private func editableCommandRange(from range: NSRange, in view: UITextView) -> NSRange {
            let fullLength = ((view.text ?? "") as NSString).length
            let start = max(promptUTF16Length, min(range.location, fullLength))
            let rawEnd = min(range.location + range.length, fullLength)
            return NSRange(location: start, length: max(0, rawEnd - start))
        }
    }
}

private extension UITextView {
    var selectedNSRange: NSRange {
        guard let range = selectedTextRange else { return NSRange(location: 0, length: 0) }
        let location = offset(from: beginningOfDocument, to: range.start)
        let length = offset(from: range.start, to: range.end)
        return NSRange(location: location, length: length)
    }
}

private final class LocalAlpineConsoleInputView: UITextView {
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        rect.origin.y = max(0, rect.origin.y + 2)
        rect.size.width = 8
        rect.size.height = max(18, rect.size.height - 3)
        return rect
    }
}

// MARK: - Terminal Browser View

/// A slide-over file browser panel for the terminal server.
///
/// Displays a file list with breadcrumb navigation, action toolbar,
/// and a mini terminal command runner at the bottom.
/// Presented as an overlay panel that slides in from the right edge.
struct TerminalBrowserView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var showFilePicker = false
    @State private var previewFileURL: URL?
    @State private var previewWebURL: WebPreviewURL?
    @State private var shareFileURL: URL?
    @State private var confirmDeleteItem: TerminalFileItem?
    @FocusState private var isCommandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // Breadcrumb navigation
            breadcrumbBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // Action toolbar
            actionToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // File list
            fileListArea

            // Mini terminal
            if viewModel.isTerminalExpanded {
                Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
                terminalSection
            }

            // Terminal toggle bar
            terminalToggleBar
        }
        .background(theme.background)
        .task {
            await viewModel.loadDirectory()
        }
        .alert("New Folder", isPresented: $viewModel.showNewFolderAlert) {
            TextField("Folder name", text: $viewModel.newFolderName)
            Button("Cancel", role: .cancel) { viewModel.newFolderName = "" }
            Button("Create") {
                let name = viewModel.newFolderName
                viewModel.newFolderName = ""
                Task { await viewModel.createFolder(name: name) }
            }
        }
        .confirmationDialog(
            "Delete \(confirmDeleteItem?.name ?? "")?",
            isPresented: Binding(
                get: { confirmDeleteItem != nil },
                set: { if !$0 { confirmDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = confirmDeleteItem {
                    Task { await viewModel.deleteItem(item) }
                }
                confirmDeleteItem = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showFilePicker) {
            TerminalDocumentPicker { urls in
                for url in urls {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        Task {
                            await viewModel.uploadFile(data: data, fileName: url.lastPathComponent)
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { viewModel.pendingInteractiveRequest },
            set: { if $0 == nil, viewModel.pendingInteractiveRequest != nil { viewModel.cancelPendingInteractiveCommand() } }
        )) { request in
            ActionInputSheet(
                request: ActionInputRequest(
                    title: request.title,
                    message: request.message,
                    placeholder: request.placeholder,
                    defaultValue: request.defaultValue
                ),
                text: $viewModel.pendingInteractiveInput,
                onConfirm: {
                    let input = viewModel.pendingInteractiveInput
                    Task { await viewModel.continuePendingInteractiveCommand(input: input) }
                },
                onCancel: {
                    viewModel.cancelPendingInteractiveCommand()
                }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .quickLookPreview($previewFileURL)
        .sheet(item: $previewWebURL) { item in
            InAppWebPreviewSheet(url: item.url)
        }
        .sheet(item: $shareFileURL) { url in
            ShareSheetView(activityItems: [url])
        }
        .onChange(of: viewModel.pendingOpenRequest) { _, request in
            handleOpenRequest(request)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Files")
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            // Placeholder for symmetry
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handleOpenRequest(_ request: LocalAlpineOpenRequest?) {
        guard let request else { return }
        viewModel.consumePendingOpenRequest(request)
        if let url = request.webURL {
            previewWebURL = WebPreviewURL(url: url)
            return
        }
        Task {
            do {
                let url = try await LocalAlpineTerminalService.shared.materializePreviewURL(for: request)
                await MainActor.run {
                    if localAlpinePreviewShouldUseWebView(url) {
                        previewWebURL = WebPreviewURL(url: url)
                    } else {
                        previewFileURL = url
                    }
                }
            } catch {
                await MainActor.run {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Breadcrumb Navigation

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(viewModel.pathSegments.enumerated()), id: \.element.path) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 9, weight: .bold)
                            .foregroundStyle(theme.textTertiary)
                    }

                    Button {
                        viewModel.navigateToPath(segment.path)
                        Haptics.play(.light)
                    } label: {
                        Text(segment.name)
                            .scaledFont(size: 13, weight: segment.path == viewModel.currentPath ? .bold : .medium)
                            .foregroundStyle(segment.path == viewModel.currentPath ? theme.brandPrimary : theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                segment.path == viewModel.currentPath
                                    ? theme.brandPrimary.opacity(0.1)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Action Toolbar

    private var actionToolbar: some View {
        HStack(spacing: 12) {
            // Refresh
            Button {
                viewModel.refresh()
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            // New folder
            Button {
                viewModel.showNewFolderAlert = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            // Upload
            Button {
                showFilePicker = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.doc")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            if viewModel.usesLocalAlpine {
                Button {
                    Task { await viewModel.executeCommand(LocalAlpineTerminalService.environmentDiagnosticCommand) }
                    Haptics.play(.light)
                } label: {
                    Label("自检", systemImage: "checkmark.circle")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Item count
            Text("\(viewModel.items.count) items")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - File List

    private var fileListArea: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading...")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .scaledFont(size: 28)
                        .foregroundStyle(theme.error)
                    Text(error)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") { viewModel.refresh() }
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.sortedItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .scaledFont(size: 28)
                        .foregroundStyle(theme.textTertiary)
                    Text("Empty directory")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.sortedItems) { item in
                        fileRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.3))
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.loadDirectory() }
            }
        }
    }

    // MARK: - File Row

    private func fileRow(_ item: TerminalFileItem) -> some View {
        Button {
            if item.isDirectory {
                viewModel.navigateToDirectory(item.path)
                Haptics.play(.light)
            } else {
                // Preview file
                Task {
                    if let url = await viewModel.downloadFile(item) {
                        previewFileURL = url
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                // Icon
                Image(systemName: item.iconName)
                    .scaledFont(size: 18)
                    .foregroundStyle(item.isDirectory ? theme.brandPrimary : iconColor(for: item))
                    .frame(width: 28)

                // Name + details
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .scaledFont(size: 14, weight: item.isDirectory ? .semibold : .regular)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let size = item.formattedSize {
                        Text(size)
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("Delete", systemImage: "trash")
            }

            if !item.isDirectory {
                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            shareFileURL = url
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(theme.brandPrimary)
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            previewFileURL = url
                        }
                    }
                } label: {
                    Label("Preview", systemImage: "eye")
                }

                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            shareFileURL = url
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }

            Button {
                UIPasteboard.general.string = item.path
                Haptics.notify(.success)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func iconColor(for item: TerminalFileItem) -> Color {
        switch item.fileExtension {
        case "py", "js", "ts", "swift", "java", "cpp", "c", "go", "rs", "rb":
            return .orange
        case "json", "yaml", "yml", "xml", "toml":
            return .purple
        case "md", "txt", "log":
            return theme.textSecondary
        case "png", "jpg", "jpeg", "gif", "svg":
            return .green
        case "pdf":
            return .red
        case "sh", "bash", "zsh":
            return .green
        default:
            return theme.textTertiary
        }
    }

    // MARK: - Terminal Toggle

    private var terminalToggleBar: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.isTerminalExpanded.toggle()
            }
            if viewModel.isTerminalExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isCommandFocused = true
                }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .scaledFont(size: 13, weight: .semibold)
                Text("Terminal")
                    .scaledFont(size: 13, weight: .semibold)
                Spacer()
                Image(systemName: viewModel.isTerminalExpanded ? "chevron.down" : "chevron.up")
                    .scaledFont(size: 11, weight: .bold)
            }
            .foregroundStyle(viewModel.isTerminalExpanded ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfaceContainer.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Terminal Section

    private var terminalSection: some View {
        VStack(spacing: 0) {
            // Command output — uses flexible height to fill available space
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.commandHistory) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                // Prompt + command
                                HStack(spacing: 4) {
                                    Text("$")
                                        .foregroundStyle(.green)
                                    Text(entry.command)
                                        .foregroundStyle(theme.textPrimary)
                                }
                                .scaledFont(size: 12, design: .monospaced)

                                // Output
                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .scaledFont(size: 11, design: .monospaced)
                                        .foregroundStyle(theme.textSecondary)
                                        .textSelection(.enabled)
                                }

                                if entry.isRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(.top, 2)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 200, maxHeight: 350)
                .background(Color.black.opacity(0.3))
                .onChange(of: viewModel.commandHistory.count) { _, _ in
                    if let last = viewModel.commandHistory.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // Command input — uses UIKit UITextField for proper return key handling.
            // Return key executes the command without dismissing the keyboard.
            HStack(spacing: 8) {
                Text("$")
                    .scaledFont(size: 14, design: .monospaced)
                    .foregroundStyle(.green)

                TerminalTextField(
                    text: $viewModel.commandInput,
                    textColor: UIColor(theme.textPrimary),
                    onReturn: {
                        let cmd = viewModel.commandInput
                        Task { await viewModel.executeCommand(cmd) }
                    }
                )
                .frame(height: 28)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
    }
}

struct LocalAlpineWorkspacePanelView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            LocalWorkspaceFileBrowserView(onDismiss: onDismiss)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
            LocalAlpinePanelMiniTerminalView(viewModel: viewModel)
        }
        .background(theme.background)
        .onAppear {
            if !viewModel.usesLocalAlpine {
                viewModel.configureLocalAlpine()
            }
        }
    }
}

private struct LocalAlpinePanelMiniTerminalView: View {
    @Bindable var viewModel: TerminalBrowserViewModel

    @Environment(\.theme) private var theme
    @State private var previewFileURL: URL?
    @State private var previewWebURL: WebPreviewURL?

    var body: some View {
        VStack(spacing: 0) {
            terminalToggleBar
            if viewModel.isTerminalExpanded {
                Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
                terminalSection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Binding(
            get: { viewModel.pendingInteractiveRequest },
            set: { if $0 == nil, viewModel.pendingInteractiveRequest != nil { viewModel.cancelPendingInteractiveCommand() } }
        )) { request in
            ActionInputSheet(
                request: ActionInputRequest(
                    title: request.title,
                    message: request.message,
                    placeholder: request.placeholder,
                    defaultValue: request.defaultValue
                ),
                text: $viewModel.pendingInteractiveInput,
                onConfirm: {
                    let input = viewModel.pendingInteractiveInput
                    Task { await viewModel.continuePendingInteractiveCommand(input: input) }
                },
                onCancel: {
                    viewModel.cancelPendingInteractiveCommand()
                }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .sheet(item: $previewWebURL) { item in
            InAppWebPreviewSheet(url: item.url)
        }
        .quickLookPreview($previewFileURL)
        .onChange(of: viewModel.pendingOpenRequest) { _, request in
            handleOpenRequest(request)
        }
    }

    private func handleOpenRequest(_ request: LocalAlpineOpenRequest?) {
        guard let request else { return }
        viewModel.consumePendingOpenRequest(request)
        if let url = request.webURL {
            previewWebURL = WebPreviewURL(url: url)
            return
        }
        Task {
            do {
                let url = try await LocalAlpineTerminalService.shared.materializePreviewURL(for: request)
                await MainActor.run {
                    if localAlpinePreviewShouldUseWebView(url) {
                        previewWebURL = WebPreviewURL(url: url)
                    } else {
                        previewFileURL = url
                    }
                }
            } catch {
                await MainActor.run {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var terminalToggleBar: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.isTerminalExpanded.toggle()
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .scaledFont(size: 13, weight: .semibold)
                Text("终端")
                    .scaledFont(size: 13, weight: .semibold)
                Spacer()
                Image(systemName: viewModel.isTerminalExpanded ? "chevron.down" : "chevron.up")
                    .scaledFont(size: 11, weight: .bold)
            }
            .foregroundStyle(viewModel.isTerminalExpanded ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfaceContainer.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var terminalSection: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.commandHistory) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("$")
                                        .foregroundStyle(.green)
                                    Text(entry.command)
                                        .foregroundStyle(theme.textPrimary)
                                }
                                .scaledFont(size: 12, design: .monospaced)

                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .scaledFont(size: 11, design: .monospaced)
                                        .foregroundStyle(theme.textSecondary)
                                        .textSelection(.enabled)
                                }

                                if entry.isRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 150, maxHeight: 240)
                .background(Color.black.opacity(0.3))
                .onChange(of: viewModel.commandHistory.count) { _, _ in
                    if let last = viewModel.commandHistory.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("$")
                    .scaledFont(size: 14, design: .monospaced)
                    .foregroundStyle(.green)

                TerminalTextField(
                    text: $viewModel.commandInput,
                    textColor: UIColor(theme.textPrimary),
                    onReturn: {
                        let cmd = viewModel.commandInput
                        Task { await viewModel.executeCommand(cmd) }
                    }
                )
                .frame(height: 28)
                .disabled(viewModel.isExecutingCommand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
    }
}

// MARK: - Slide-Over Panel Container

/// A container that presents the terminal browser as a right-edge slide-over panel.
/// Manages the open/close animation and background dimming.
struct TerminalSlideOverPanel: View {
    @Binding var isOpen: Bool
    @Bindable var viewModel: TerminalBrowserViewModel

    @Environment(\.theme) private var theme
    @GestureState private var dragOffset: CGFloat = 0

    /// Panel width as percentage of screen.
    private let panelWidthRatio: CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width * panelWidthRatio
            let offsetX = isOpen ? 0 : panelWidth

            ZStack(alignment: .trailing) {
                // Dim background
                if isOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                isOpen = false
                            }
                        }
                        .transition(.opacity)
                }

                // Panel
                TerminalBrowserView(
                    viewModel: viewModel,
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isOpen = false
                        }
                    }
                )
                .frame(width: panelWidth)
                .background(theme.background)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 20, x: -5)
                .offset(x: max(0, offsetX + dragOffset))
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            // Only allow dragging right (to dismiss)
                            if value.translation.width > 0 {
                                state = value.translation.width
                            }
                        }
                        .onEnded { value in
                            // If dragged more than 30% of panel width, dismiss
                            if value.translation.width > panelWidth * 0.3 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isOpen = false
                                }
                            }
                        }
                )
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
        }
    }
}

// MARK: - Right Edge Swipe Gesture

/// A UIViewRepresentable that detects right-edge swipe gestures.
/// Triggers the file browser panel when the user swipes from the right edge.
struct RightEdgeSwipeGesture: UIViewRepresentable {
    var isEnabled: Bool
    var onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true

        let edgeGesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgeSwipe(_:))
        )
        edgeGesture.edges = .right
        view.addGestureRecognizer(edgeGesture)
        context.coordinator.gesture = edgeGesture

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.gesture?.isEnabled = isEnabled
        context.coordinator.onSwipe = onSwipe
    }

    class Coordinator: NSObject {
        var onSwipe: () -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?

        init(onSwipe: @escaping () -> Void) {
            self.onSwipe = onSwipe
        }

        @objc func handleEdgeSwipe(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            if recognizer.state == .recognized {
                onSwipe()
            }
        }
    }
}

// MARK: - Helper Views

/// Document picker for terminal file upload.
private struct TerminalDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

/// A UIKit-backed text field for the terminal command input.
///
/// Uses `UITextField` directly so we can intercept the return key via
/// `textFieldShouldReturn` and return `false` — this executes the command
/// **without** dismissing the keyboard, which SwiftUI's `TextField.onSubmit`
/// cannot do.
private struct TerminalTextField: UIViewRepresentable {
    @Binding var text: String
    var textColor: UIColor
    var onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = textColor
        field.tintColor = textColor
        field.attributedPlaceholder = NSAttributedString(
            string: "command…",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .default
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Only update text if it actually changed (avoid cursor jump)
        if field.text != text {
            field.text = text
        }
        field.textColor = textColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onReturn: onReturn)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var onReturn: () -> Void

        init(text: Binding<String>, onReturn: @escaping () -> Void) {
            _text = text
            self.onReturn = onReturn
        }

        @objc func textChanged(_ field: UITextField) {
            text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            // Execute command, keep keyboard open
            onReturn()
            return false
        }
    }
}

