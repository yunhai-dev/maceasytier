import Darwin
import Foundation

/// 负责 core/helper 定位、配置校验与 core 版本读取；运行期数据全部走原生 RPC。
enum CLIBridge {
    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Locate

    static func locateCore() -> URL? {
        locateExecutable(named: "easytier-core", environmentKey: "EASYTIER_CORE_PATH")
    }

    static func locateHelper() -> URL? {
        locateExecutable(named: "MacEasyTierHelper", environmentKey: "EASYTIER_HELPER_PATH")
    }

    private static func locateExecutable(named name: String, environmentKey: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let override = environment[environmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.deletingLastPathComponent().appendingPathComponent("Helpers/\(name)"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Commands

    static func version(executable: URL) async -> String? {
        guard let output = try? await run(executable: executable, arguments: ["--version"]) else { return nil }
        return output
            .split(separator: " ")
            .last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func validate(configFile: URL, core: URL) async throws {
        let output = try await run(
            executable: core,
            arguments: ["--disable-env-parsing", "--check-config", "--config-file", configFile.path]
        )
        if !output.isEmpty {
            let combined = output.lowercased()
            if combined.contains("error") || combined.contains("failed") {
                throw CommandError(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    static func run(executable: URL, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executable: executable, arguments: arguments)
        }.value
    }

    private static func runSync(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CommandError(message: "无法运行 \(executable.lastPathComponent)：\(error.localizedDescription)")
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: output, encoding: .utf8) ?? ""
        let stderr = String(data: errorOutput, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw CommandError(message: detail.isEmpty ? "easytier-core 退出码 \(process.terminationStatus)" : detail)
        }

        return stdout
    }
}

/// 读取一个空闲 TCP 端口，交给 core 的 RPC portal。
enum PortAllocator {
    static func freePort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return 15888 }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0 else { return 15888 }

        var bound = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }
}
