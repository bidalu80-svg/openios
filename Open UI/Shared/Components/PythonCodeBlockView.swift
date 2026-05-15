import SwiftUI
import MarkdownView

// MARK: - Python Code Block View

/// Renders a Python code block with a "Run" button and an inline output panel.
///
/// The code is displayed using `MarkdownView` (same engine as all other code blocks)
/// which provides full syntax highlighting via HighlightSwift. Pressing "Run"
/// executes the code in the bundled Local Alpine runtime so imports, packages,
/// network, and files match the app's terminal environment.
struct PythonCodeBlockView: View {

    let code: String

    // MARK: - Execution State

    enum RunState: Equatable {
        case idle
        case loading        // Local runtime preparing
        case running        // Code executing
        case done(result: PythonExecutionResult)

        static func == (lhs: RunState, rhs: RunState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.running, .running): return true
            case (.done, .done): return true
            default: return false
            }
        }
    }

    @State private var runState: RunState = .idle
    @State private var codeCopied = false
    @State private var showFullCode = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    private var scaledTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        var t = MarkdownTheme.default
        if abs(scale - 1.0) > 0.01 {
            t.align(to: Self.baseBodyFontSize * scale)
        }
        return t
    }

    // The markdown string that produces a syntax-highlighted Python block
    private var markdownCodeBlock: String {
        "```python\n\(displayCode)\n```"
    }

    private var displayCode: String {
        Self.codeBlockSource(code)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            headerBar

            // ── Code body (MarkdownView handles syntax highlighting) ─────────
            MarkdownView(markdownCodeBlock, theme: scaledTheme).codeBarHidden(true)

            // ── Output panel (shown after run) ──────────────────────────────
            if case .loading = runState {
                loadingPanel
            } else if case .running = runState {
                runningPanel
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

    // MARK: - Output Panel

    @ViewBuilder
    private func outputPanel(result: PythonExecutionResult) -> some View {
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
            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView(.vertical) {
                    Text(result.stdout)
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
            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .overlay(Color.primary.opacity(0.06))
                ScrollView(.vertical) {
                    Text(result.stderr)
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
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
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
        runState = .running
        let codeToRun = Self.codeBlockSource(code)
        Task {
            let result = await Self.runCodeInLocalAlpine(code: codeToRun)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.runState = .done(result: result)
                }
                if result.status == .success {
                    Haptics.notify(.success)
                } else {
                    Haptics.notify(.error)
                }
            }
        }
    }

    private static func runCodeInLocalAlpine(code: String) async -> PythonExecutionResult {
        let fileName = "codeblock-\(UUID().uuidString.prefix(8)).py"
        let source = codeBlockSource(code)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PythonExecutionResult(
                status: .error,
                stdout: "",
                stderr: "Python 代码为空，无法运行。",
                images: []
            )
        }
        let marker = shellHereDocMarker(for: source)
        let body = source.hasSuffix("\n") ? source : source + "\n"
        let quotedFile = shellSingleQuoted(fileName)
        let command = """
        cat > \(quotedFile) <<'\(marker)'
        \(body)\(marker)
        python3 -m py_compile \(quotedFile) && python3 \(quotedFile)
        status=$?
        rm -f \(quotedFile)
        exit $status
        """
        let result = await LocalAlpineTerminalService.shared.execute(command: command, cwd: "/mnt/iexa")
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            return PythonExecutionResult(status: .success, stdout: output, stderr: "", images: [])
        }
        return PythonExecutionResult(
            status: .error,
            stdout: "",
            stderr: output.isEmpty ? "Local Alpine 执行失败，退出码：\(result.exitCode.map(String.init) ?? "unknown")" : output,
            images: []
        )
    }

    private static func codeBlockSource(_ code: String) -> String {
        let normalizedNewlines = code.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedNewlines.trimmingCharacters(in: .newlines)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func shellHereDocMarker(for content: String, prefix: String = "IEXA_PY") -> String {
        var marker = prefix
        var suffix = 0
        let lines = Set(content.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        while lines.contains(marker) {
            suffix += 1
            marker = "\(prefix)_\(suffix)"
        }
        return marker
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
