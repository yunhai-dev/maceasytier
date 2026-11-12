import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.example.maceasytier"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacEasyTier", isDirectory: true)
    }

    static var networksDirectory: URL {
        supportDirectory.appendingPathComponent("networks", isDirectory: true)
    }

    static var stateFile: URL {
        supportDirectory.appendingPathComponent("state.json")
    }

    static func ensureDirectories() {
        for directory in [supportDirectory, networksDirectory] {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    static func networkDirectory(for id: UUID) -> URL {
        networksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func configFile(for id: UUID) -> URL {
        networkDirectory(for: id).appendingPathComponent("config.toml")
    }

    static func logFile(for id: UUID) -> URL {
        networkDirectory(for: id).appendingPathComponent("core.log")
    }

    /// 控制 socket 放在 /tmp，避免 Application Support 长路径超过 sun_path 104 字节。
    static func socketFile(for id: UUID) -> URL {
        URL(fileURLWithPath: "/tmp/maceasytier-\(id.uuidString).sock")
    }

    static func prepareNetworkDirectory(for id: UUID) throws {
        let directory = networkDirectory(for: id)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
