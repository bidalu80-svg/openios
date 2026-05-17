import SwiftUI
import MarkdownView

// MARK: - Python Code Block View

/// Renders a Python code block with a "Run" button and an inline output panel.
///
/// The code is displayed and copied as the original source so indentation stays
/// runnable. Pressing "Run" executes the same source in Local Alpine.
struct PythonCodeBlockView: View {

    let code: String

    // MARK: - Execution State

    enum RunState: Equatable {
        case idle
        case loading        // Local runtime preparing
        case running        // Code executing
        case waitingForInput // Code paused for stdin
        case done(result: PythonExecutionResult)

        static func == (lhs: RunState, rhs: RunState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.running, .running), (.waitingForInput, .waitingForInput): return true
            case (.done, .done): return true
            default: return false
            }
        }
    }

    @State private var runState: RunState = .idle
    @State private var codeCopied = false
    @State private var showFullCode = false
    @State private var pendingInteractiveRequest: LocalAlpineInteractiveRequest?
    @State private var pendingInteractiveInput = ""

    @Environment(\.theme) private var theme

    private var displayCode: String {
        Self.displayablePythonCode(code)
    }

    private var visibleCode: String {
        InlineDataPayloadSanitizer.sanitizedDisplayText(displayCode)
    }

    private var fencedCodeMarkdown: String {
        let fence = visibleCode.contains("```") ? "````" : "```"
        let body = visibleCode.isEmpty ? " " : visibleCode
        return "\(fence)python\n\(body)\n\(fence)"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            headerBar

            MarkdownView(fencedCodeMarkdown)
                .codeBarHidden(true)
            .background(Color(.secondarySystemBackground))

            // ── Output panel (shown after run) ──────────────────────────────
            if case .loading = runState {
                loadingPanel
            } else if case .running = runState {
                runningPanel
            } else if case .waitingForInput = runState {
                waitingInputPanel
            } else if case .done(let result) = runState {
                outputPanel(result: result)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .sheet(isPresented: $showFullCode) {
            FullCodeView(code: displayCode, language: "python")
        }
        .sheet(item: $pendingInteractiveRequest) { request in
            let actionRequest = Self.actionInputRequest(for: request, code: displayCode)
            ActionInputSheet(
                request: actionRequest,
                text: $pendingInteractiveInput,
                onConfirm: {
                    let input = pendingInteractiveInput
                    pendingInteractiveRequest = nil
                    pendingInteractiveInput = ""
                    continueInteractiveRun(input: input)
                },
                onCancel: {
                    pendingInteractiveRequest = nil
                    pendingInteractiveInput = ""
                    cancelInteractiveRun()
                }
            )
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Language label
            Label("Python", systemImage: "chevron.left.forwardslash.chevron.right")
                .labelStyle(.titleOnly)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

            // Copy button
            Button {
                UIPasteboard.general.string = displayCode
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Fullscreen button
            Button {
                showFullCode = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Run button
            runButton
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var runButton: some View {
        let isActive = runState == .loading || runState == .running

        Button {
            guard !isActive else { return }
            runCode()
        } label: {
            HStack(spacing: 5) {
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .scaledFont(size: 10, weight: .bold)
                }
                Text(isActive ? "运行中…" : "运行")
                    .scaledFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.gray : Color.accentColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    // MARK: - Status Panels

    private var loadingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Text("正在加载 Python 运行环境…")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private var runningPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Text("正在执行…")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private var waitingInputPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(.orange)
            Text("等待输入…")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer()
            Button("填写") {
                if let request = pendingInteractiveRequest {
                    pendingInteractiveInput = request.defaultValue
                    pendingInteractiveRequest = request
                }
            }
            .scaledFont(size: 12, weight: .semibold)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Output Panel

    @ViewBuilder
    private func outputPanel(result: PythonExecutionResult) -> some View {
        let visibleStdout = InlineDataPayloadSanitizer.sanitizedDisplayText(result.stdout)
        let visibleStderr = InlineDataPayloadSanitizer.sanitizedDisplayText(result.stderr)
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .overlay(Color.primary.opacity(0.08))

            // Output header
            HStack(spacing: 6) {
                Image(systemName: result.status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .scaledFont(size: 11)
                    .foregroundStyle(result.status == .success ? .green : .red)
                Text("输出")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                // Re-run button
                Button {
                    runCode()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04))

            Divider()
                .overlay(Color.primary.opacity(0.08))

            // stdout
            if !visibleStdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.vertical) {
                    Text(visibleStdout)
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .background(Color(.secondarySystemBackground))
            }

            // stderr
            if !visibleStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .overlay(Color.primary.opacity(0.06))
                ScrollView(.vertical) {
                    Text(visibleStderr)
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(.red)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .background(Color(.secondarySystemBackground))
            }

            // matplotlib images
            if !result.images.isEmpty {
                Divider()
                    .overlay(Color.primary.opacity(0.06))
                VStack(spacing: 8) {
                    ForEach(Array(result.images.enumerated()), id: \.offset) { _, b64 in
                        if let data = Data(base64Encoded: b64),
                           let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contextMenu {
                                    Button {
                                        UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
                                        Haptics.notify(.success)
                                    } label: {
                                        Label("保存到相册", systemImage: "photo")
                                    }
                                    Button {
                                        UIPasteboard.general.image = uiImage
                                        Haptics.notify(.success)
                                    } label: {
                                        Label("复制图片", systemImage: "doc.on.doc")
                                    }
                                }
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
            }

            // Empty output
            if visibleStdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               visibleStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               result.images.isEmpty {
                HStack {
                    Text("（无输出）")
                        .scaledFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .italic()
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
        }
    }

    // MARK: - Run Action

    private func runCode() {
        pendingInteractiveRequest = nil
        pendingInteractiveInput = ""
        executeCode(stdinInput: nil)
    }

    private func continueInteractiveRun(input: String) {
        executeCode(stdinInput: input)
    }

    private func cancelInteractiveRun() {
        withAnimation(.easeInOut(duration: 0.2)) {
            runState = .done(result: PythonExecutionResult(
                status: .error,
                stdout: "",
                stderr: "已取消输入，本次 Python 执行已停止。",
                images: []
            ))
        }
        Haptics.notify(.warning)
    }

    private static func actionInputRequest(
        for request: LocalAlpineInteractiveRequest,
        code: String
    ) -> ActionInputRequest {
        let inputCount = pythonInputCallCount(in: code)
        guard inputCount > 1 else {
            return ActionInputRequest(
                title: request.title,
                message: request.message,
                placeholder: request.placeholder,
                defaultValue: request.defaultValue
            )
        }

        let example = interactiveInputExample(for: code, inputCount: inputCount)
        return ActionInputRequest(
            title: "需要输入 \(inputCount) 行",
            message: "这段 Python 会连续调用 \(inputCount) 次 input()。请一次性填写所有输入，每个 input() 对应一行；如果是菜单循环，最后一行填写退出选项。",
            placeholder: example,
            defaultValue: request.defaultValue
        )
    }

    private static func pythonInputCallCount(in code: String) -> Int {
        let pattern = #"(?m)(?<![A-Za-z0-9_])(?:input|raw_input)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.numberOfMatches(in: code, range: range)
    }

    private static func interactiveInputExample(for code: String, inputCount: Int) -> String {
        let lowercased = code.lowercased()
        if lowercased.contains("while true") || lowercased.contains("while 1") {
            return "例如：\n1\n张三\n95\n5"
        }
        if inputCount >= 3 {
            return "例如：\n1\n张三\n95"
        }
        return "例如：\n张三\n95"
    }

    private func executeCode(stdinInput: String?) {
        runState = .running
        let codeToRun = displayCode
        Task {
            let outcome = await Self.runCodeInLocalAlpine(code: codeToRun, stdinInput: stdinInput)
            await MainActor.run {
                if let request = outcome.interactiveRequest {
                    pendingInteractiveInput = request.defaultValue
                    pendingInteractiveRequest = request
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.runState = .waitingForInput
                    }
                    Haptics.notify(.warning)
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.runState = .done(result: outcome.result)
                }
                if outcome.result.status == .success {
                    Haptics.notify(.success)
                } else {
                    Haptics.notify(.error)
                }
            }
        }
    }

    private static func runCodeInLocalAlpine(code: String, stdinInput: String? = nil) async -> PythonCodeRunOutcome {
        let fileName = "codeblock-\(UUID().uuidString.prefix(8)).py"
        let source = displayablePythonCode(code)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PythonCodeRunOutcome(result: PythonExecutionResult(
                status: .error,
                stdout: "",
                stderr: "Python 代码为空，无法运行。",
                images: []
            ))
        }
        let agentResult = await LocalAlpineAgentService.shared.runPythonCodeBlock(
            source,
            fileName: fileName,
            cwd: "/mnt/iexa",
            stdinInput: stdinInput
        )
        if let interactiveRequest = agentResult.interactiveRequest {
            return PythonCodeRunOutcome(
                result: PythonExecutionResult(status: .error, stdout: "", stderr: agentResult.summary, images: []),
                interactiveRequest: interactiveRequest
            )
        }
        let output = agentResult.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agentResult.hadFailure {
            let visibleOutput = userVisibleSuccessOutput(from: userVisiblePythonOutput(from: output))
            return PythonCodeRunOutcome(result: PythonExecutionResult(status: .success, stdout: visibleOutput, stderr: "", images: []))
        }
        return PythonCodeRunOutcome(result: PythonExecutionResult(
            status: .error,
            stdout: "",
            stderr: output.isEmpty ? "Local Alpine 执行失败。" : output,
            images: []
        ))
    }

    private static func userVisiblePythonOutput(from agentSummary: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)输出\s*\n\s*```text\s*\n([\s\S]*?)\n\s*```"#
        ) else {
            return agentSummary
        }
        let range = NSRange(agentSummary.startIndex..<agentSummary.endIndex, in: agentSummary)
        let matches = regex.matches(in: agentSummary, range: range)
        guard let match = matches.last,
              match.numberOfRanges >= 2,
              let swiftRange = Range(match.range(at: 1), in: agentSummary) else {
            return agentSummary
        }
        return String(agentSummary[swiftRange])
    }

    private static func userVisibleSuccessOutput(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isLocalAlpineNoOutputDiagnostic(trimmed) {
            return """
            运行成功，但代码没有产生输出。

            Python 只有执行 print()/日志输出/图像显示时才会在这里显示结果；仅定义变量、列表、函数或类不会自动显示计算结果。
            """
        }
        return trimmed
    }

    private static func isLocalAlpineNoOutputDiagnostic(_ output: String) -> Bool {
        output.range(
            of: #"(?is)^Local Alpine command exited without output\.\s*pid=\d+\s+shell=[^\s]+\s+cwd=[^\s]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func displayablePythonCode(_ code: String) -> String {
        code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

}

private struct PythonCodeRunOutcome {
    let result: PythonExecutionResult
    let interactiveRequest: LocalAlpineInteractiveRequest?

    init(result: PythonExecutionResult, interactiveRequest: LocalAlpineInteractiveRequest? = nil) {
        self.result = result
        self.interactiveRequest = interactiveRequest
    }
}

// MARK: - Preview

#Preview("Python Code Block") {
    ScrollView {
        VStack(spacing: 16) {
            PythonCodeBlockView(code: """
                import math

                def fibonacci(n):
                    if n <= 1:
                        return n
                    return fibonacci(n-1) + fibonacci(n-2)

                for i in range(10):
                    print(f"fib({i}) = {fibonacci(i)}")
                """)

            PythonCodeBlockView(code: """
                import numpy as np
                import matplotlib.pyplot as plt

                x = np.linspace(0, 2 * np.pi, 100)
                y = np.sin(x)

                plt.figure(figsize=(8, 4))
                plt.plot(x, y, 'b-', linewidth=2)
                plt.title('Sine Wave')
                plt.grid(True)
                plt.show()
                """)
        }
        .padding()
    }
    .themed()
}
