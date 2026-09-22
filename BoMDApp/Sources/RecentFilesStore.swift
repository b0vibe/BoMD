import Combine
import Foundation

final class RecentFilesStore: ObservableObject {
    static let shared = RecentFilesStore()

    @Published private(set) var fileURLs: [URL] = []

    private let defaultsKey = "recentMarkdownFilePaths"
    private let maximumCount = 5

    private init() {
        load()
    }

    func record(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        fileURLs.removeAll { $0.standardizedFileURL.path == normalizedURL.path }
        fileURLs.insert(normalizedURL, at: 0)
        fileURLs = Array(fileURLs.prefix(maximumCount))
        persist()
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        fileURLs.removeAll { $0.standardizedFileURL.path == path }
        persist()
    }

    func clear() {
        fileURLs = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        var seenPaths = Set<String>()
        fileURLs = paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isSupportedMarkdownFile(url),
                  FileManager.default.fileExists(atPath: url.path),
                  seenPaths.insert(url.path).inserted else {
                return nil
            }
            return url
        }
        fileURLs = Array(fileURLs.prefix(maximumCount))
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(fileURLs.map(\.path), forKey: defaultsKey)
    }

    private static func isSupportedMarkdownFile(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "md" || extensionName == "markdown"
    }
}
