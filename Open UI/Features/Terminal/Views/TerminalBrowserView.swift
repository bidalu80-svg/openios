import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import UIKit

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
    @State private var commandInputHeight: CGFloat = 34

    private let prompt = "root@iexa:~#"
    private let terminalGreen = Color(red: 0.24, green: 0.82, blue: 0.36)
    @State private var cwd = "/mnt/iexa"

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(prompt) \(entry.command)")
                                        .font(.system(size: 18, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .textSelection(.enabled)

                                    if !entry.output.isEmpty {
                                        Text(entry.output)
                                            .font(.system(size: 17, weight: .regular, design: .monospaced))
                                            .foregroundStyle(terminalGreen.opacity(0.88))
                                            .textSelection(.enabled)
                                    } else if entry.isRunning {
                                        Text("执行中...")
                                            .font(.system(size: 17, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.45))
                                    } else if let exitCode = entry.exitCode, exitCode != 0 {
                                        Text("[exit \(exitCode), no output]")
                                            .font(.system(size: 17, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.45))
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                            }

                            commandLine
                                .id("commandLine")
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                    .onChange(of: entries.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("commandLine", anchor: .bottom)
                        }
                    }
                    .onChange(of: commandInputHeight) { _, _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("commandLine", anchor: .bottom)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            refocusCommandLine()
        }
        .task {
            refocusCommandLine()
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
    }

    private var headerBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")

            Spacer()

            Button {
                entries.removeAll()
                commandInput = ""
                historyCursor = nil
                isControlLatched = false
                isAccessoryBarHidden = false
                refocusCommandLine()
                Haptics.play(.light)
            } label: {
                Image(systemName: "paintbrush")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清空")
        }
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
            controlLatch: $isControlLatched,
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
                    Task { await executeCurrentCommand() }
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
    }

    private func accessoryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.24, green: 0.82, blue: 0.36))
                .lineLimit(1)
                .frame(height: 36)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func accessoryTextButton(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color(red: 0.24, green: 0.82, blue: 0.36))
                .lineLimit(1)
                .frame(height: 36)
                .padding(.horizontal, 14)
                .background(active ? Color(red: 0.24, green: 0.82, blue: 0.36) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func executeCurrentCommand() async {
        let command = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }

        commandInput = ""
        commandHistory.append(command)
        historyCursor = nil
        isControlLatched = false
        isRunning = true
        Haptics.play(.light)

        entries.append(LocalAlpineConsoleEntry(command: command, output: "", exitCode: nil, isRunning: true))
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: cwd)
        applyResult(result)
        updateWorkingDirectory(after: command, result: result)
    }

    private func continueInteractiveCommand(_ request: LocalAlpineInteractiveRequest, input: String) async {
        pendingInteractiveRequest = nil
        pendingInteractiveInput = ""
        isRunning = true

        let result = await LocalAlpineTerminalService.shared.execute(
            command: request.command,
            cwd: request.cwd,
            stdinInput: input
        )
        applyResult(result)
        updateWorkingDirectory(after: request.command, result: result)
    }

    private func applyResult(_ result: LocalAlpineCommandResult) {
        if let index = entries.indices.last {
            entries[index].output = visibleOutput(for: result)
            entries[index].exitCode = result.exitCode
            entries[index].isRunning = result.interactiveRequest != nil
        }

        if let request = result.interactiveRequest {
            pendingInteractiveInput = request.defaultValue
            pendingInteractiveRequest = request
            isRunning = false
            return
        }

        isRunning = false
        refocusCommandLine()
    }

    private func appendSystemOutput(_ output: String, exitCode: Int?) {
        if let index = entries.indices.last {
            entries[index].output += entries[index].output.isEmpty ? output : "\n\(output)"
            entries[index].exitCode = exitCode
            entries[index].isRunning = false
        }
        isRunning = false
        refocusCommandLine()
    }

    private func appendRunningNotice(_ output: String) {
        if let index = entries.indices.last {
            entries[index].output += entries[index].output.isEmpty ? output : "\n\(output)"
        }
    }

    private func visibleOutput(for result: LocalAlpineCommandResult) -> String {
        let output = result.output.trimmingCharacters(in: .newlines)
        guard output.isEmpty else { return result.output }
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
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func cancelCurrentInput() {
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
        if isRunning {
            let sent = LocalAlpineTerminalService.shared.interruptRunningCommand()
            appendRunningNotice(sent ? "^C" : "[Ctrl-C 发送失败；当前命令会在返回或超时后结束]")
        } else if !commandInput.isEmpty {
            entries.append(LocalAlpineConsoleEntry(command: commandInput, output: "^C", exitCode: 130, isRunning: false))
            commandInput = ""
            historyCursor = nil
            refocusCommandLine()
        } else {
            entries.append(LocalAlpineConsoleEntry(command: "^C", output: "", exitCode: 130, isRunning: false))
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
        commandInput = command
        Task { await executeCurrentCommand() }
    }

    private func updateWorkingDirectory(after command: String, result: LocalAlpineCommandResult) {
        guard result.exitCode == 0, result.interactiveRequest == nil else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cd ") || trimmed == "cd" || trimmed == "cd ~" else { return }

        let target = trimmed == "cd" || trimmed == "cd ~"
            ? "/mnt/iexa"
            : String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard target.range(of: #"[;&|`$<>(){}]"#, options: .regularExpression) == nil else { return }

        if target == "/" || target == "/mnt/iexa" || target == "~" {
            cwd = "/mnt/iexa"
        } else if target.hasPrefix("/mnt/iexa") {
            cwd = normalizedConsolePath(target)
        } else if target.hasPrefix("/") {
            cwd = normalizedConsolePath("/mnt/iexa\(target)")
        } else if target == ".." {
            let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            cwd = parent.hasPrefix("/mnt/iexa") ? parent : "/mnt/iexa"
        } else if target.hasPrefix("../") {
            var path = cwd
            for component in target.split(separator: "/").map(String.init) {
                if component == ".." {
                    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    path = parent.hasPrefix("/mnt/iexa") ? parent : "/mnt/iexa"
                } else if component != "." {
                    path += "/\(component)"
                }
            }
            cwd = normalizedConsolePath(path)
        } else {
            cwd = normalizedConsolePath(cwd + "/" + target)
        }
    }

    private func normalizedConsolePath(_ rawPath: String) -> String {
        var path = rawPath.replacingOccurrences(of: "\\", with: "/")
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        guard path.hasPrefix("/mnt/iexa") else { return "/mnt/iexa" }
        return path
    }
}

private struct LocalAlpineConsoleEntry: Identifiable {
    let id = UUID()
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
    @Binding var controlLatch: Bool
    var onReturn: () -> Void
    var onControlCharacter: (Character) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = LocalAlpineConsoleInputView()
        view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
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
            onReturn: @escaping () -> Void,
            onControlCharacter: @escaping (Character) -> Void
        ) {
            self.prompt = prompt
            _text = text
            _isFocused = isFocused
            _measuredHeight = measuredHeight
            _controlLatch = controlLatch
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
                onReturn()
                return false
            }

            let sanitized = Self.sanitizedInlineText(string)
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
                let sanitized = Self.sanitizedInlineText(value)
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

        private static func sanitizedInlineText(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
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
            let maxHeight: CGFloat = 360
            let height = max(34, min(maxHeight, ceil(view.sizeThatFits(fittingSize).height)))
            if abs(measuredHeight - height) > 0.5 {
                DispatchQueue.main.async {
                    self.measuredHeight = height
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
        .sheet(item: $shareFileURL) { url in
            ShareSheetView(activityItems: [url])
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

