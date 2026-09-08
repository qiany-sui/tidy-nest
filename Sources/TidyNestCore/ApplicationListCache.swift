import Foundation

public struct ApplicationListSnapshot: Codable, Sendable, Equatable {
    public let applications: [MoleApplication]
    public let updatedAt: Date

    public init(applications: [MoleApplication], updatedAt: Date) {
        self.applications = applications
        self.updatedAt = updatedAt
    }
}

public struct ApplicationListCache: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static var standard: ApplicationListCache {
        ApplicationListCache(fileURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TidyNest/applications.json"))
    }

    public func load() -> ApplicationListSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ApplicationListSnapshot.self, from: data)
    }

    public func save(_ snapshot: ApplicationListSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
