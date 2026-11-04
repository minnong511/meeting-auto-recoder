import Foundation

package struct SummaryModel: Identifiable, Sendable, Equatable {
    package let id: String
    package let title: String

    package init?(_ rawID: String, title: String? = nil) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/+@[]")
        guard id.utf8.count <= 256,
              id.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true,
              id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.id = id
        self.title = title.flatMap { $0.isEmpty ? nil : $0 } ?? id
    }
}

extension SummaryAgent {
    package var modelPreferenceKey: String { "summaryModel-" + rawValue }

    package func savedModel(in defaults: UserDefaults = .standard) -> SummaryModel? {
        defaults.string(forKey: modelPreferenceKey).flatMap { SummaryModel($0) }
    }

    package func modelOptions(codexHome: URL? = nil) -> [SummaryModel] {
        if self == .claude {
            return ["sonnet", "haiku", "opus", "fable"].compactMap { SummaryModel($0, title: $0.capitalized) }
        }

        // Use the local catalog without launching an agent or requesting a model list over the network.
        let home = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let file = home.appendingPathComponent("models_cache.json")
        struct Catalog: Decodable {
            struct Entry: Decodable {
                var slug: String
                var display_name: String?
                var visibility: String?
            }
            var models: [Entry]
        }
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= 8 * 1024 * 1024,
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            var seen = Set<String>()
            let models = catalog.models.compactMap { entry -> SummaryModel? in
                guard entry.visibility == "list", let model = SummaryModel(entry.slug, title: entry.display_name),
                      seen.insert(model.id).inserted else { return nil }
                return model
            }
            return models
        }
        return ["gpt-6-luna", "gpt-6.1-sol"].compactMap { SummaryModel($0) }
    }
}
