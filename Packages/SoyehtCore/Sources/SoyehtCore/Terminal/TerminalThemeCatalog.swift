import Foundation

public struct TerminalThemeCatalog: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String
    public let indexURL: URL
    public let homepageURL: URL

    public init(
        id: String,
        displayName: String,
        description: String,
        indexURL: URL,
        homepageURL: URL
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.indexURL = indexURL
        self.homepageURL = homepageURL
    }
}

public extension TerminalThemeCatalog {
    static let iTerm2ColorSchemes = TerminalThemeCatalog(
        id: "iterm2-color-schemes",
        displayName: "iTerm2 Color Schemes",
        description: "Community terminal themes from mbadolato/iTerm2-Color-Schemes.",
        indexURL: URL(string: "https://api.github.com/repos/mbadolato/iTerm2-Color-Schemes/contents/schemes?ref=master")!,
        homepageURL: URL(string: "https://github.com/mbadolato/iTerm2-Color-Schemes")!
    )

    static let standardCatalogs: [TerminalThemeCatalog] = [
        .iTerm2ColorSchemes,
    ]
}

public struct TerminalThemeCatalogItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let catalogID: String
    public let displayName: String
    public let filename: String
    public let downloadURL: URL
    public let htmlURL: URL?

    public init(
        id: String,
        catalogID: String,
        displayName: String,
        filename: String,
        downloadURL: URL,
        htmlURL: URL?
    ) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.filename = filename
        self.downloadURL = downloadURL
        self.htmlURL = htmlURL
    }
}

public final class TerminalThemeCatalogClient {
    public let catalog: TerminalThemeCatalog

    public init(catalog: TerminalThemeCatalog = .iTerm2ColorSchemes) {
        self.catalog = catalog
    }

    public func fetchItems() async throws -> [TerminalThemeCatalogItem] {
        let data = try await fetchData(from: catalog.indexURL)
        return try Self.items(fromGitHubContentsData: data, catalogID: catalog.id)
    }

    @discardableResult
    public func install(
        _ item: TerminalThemeCatalogItem,
        into store: TerminalThemeStore = .shared
    ) async throws -> TerminalColorTheme {
        let data = try await fetchData(from: item.downloadURL)
        let imported = try TerminalThemeImporter.importTheme(
            data: data,
            filename: item.filename,
            sourceURL: item.downloadURL.absoluteString
        )

        let existingID = store.installedThemes()
            .first { $0.sourceURL == item.downloadURL.absoluteString }?
            .id

        return try store.saveImportedTheme(imported, replacing: existingID)
    }

    public static func items(
        fromGitHubContentsData data: Data,
        catalogID: String
    ) throws -> [TerminalThemeCatalogItem] {
        let contents = try JSONDecoder().decode([GitHubContentItem].self, from: data)
        return contents
            .compactMap { item -> TerminalThemeCatalogItem? in
                guard item.type == "file",
                      item.name.lowercased().hasSuffix(".itermcolors"),
                      let rawDownloadURL = item.downloadURL,
                      let downloadURL = URL(string: rawDownloadURL) else {
                    return nil
                }

                let displayName = displayName(fromFilename: item.name)
                return TerminalThemeCatalogItem(
                    id: "\(catalogID):\(TerminalColorTheme.slug(displayName))",
                    catalogID: catalogID,
                    displayName: displayName,
                    filename: item.name,
                    downloadURL: downloadURL,
                    htmlURL: item.htmlURL.flatMap(URL.init(string:))
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Soyeht", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw TerminalThemeError.invalidCatalogResponse("Theme catalog request failed with HTTP \(http.statusCode).")
        }
        return data
    }

    private static func displayName(fromFilename filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let decoded = base.removingPercentEncoding ?? base
        return decoded
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitHubContentItem: Decodable {
    let name: String
    let type: String
    let downloadURL: String?
    let htmlURL: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case downloadURL = "download_url"
        case htmlURL = "html_url"
    }
}
