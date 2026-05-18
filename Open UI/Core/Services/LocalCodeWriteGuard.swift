import Foundation

enum LocalCodeWriteGuard {
    static func language(forPath path: String) -> String {
        switch fileExtension(forPath: path) {
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "swift": return "swift"
        case "json", "jsonc": return "json"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "sh", "bash", "zsh": return "bash"
        case "xml": return "xml"
        case "sql": return "sql"
        case "rb": return "ruby"
        case "php": return "php"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "go": return "go"
        case "rs": return "rust"
        case "c": return "c"
        case "cc", "cpp", "cxx", "hpp", "h": return "cpp"
        case "cs": return "csharp"
        case "lua": return "lua"
        default: return "text"
        }
    }

    private static func fileExtension(forPath path: String) -> String {
        ((path as NSString).pathExtension).lowercased()
    }
}
