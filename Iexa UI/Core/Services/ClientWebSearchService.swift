import Foundation

struct ClientWebSearchService: Sendable {
    init(apiClient: APIClient? = nil) {}

    func search(queries: [String], originalQuery: String?) async throws -> WebSearchResponse {
        let normalizedQueries = Self.unique(queries.map(Self.normalizedQuery))
        guard !normalizedQueries.isEmpty else { return WebSearchResponse() }

        return await BrowserWebSearchService.shared.search(
            queries: Array(normalizedQueries.prefix(4)),
            originalQuery: originalQuery ?? normalizedQueries.first
        )
    }

    private static func normalizedQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }
}
