import CryptoKit
import Darwin
import Foundation

/// 与常驻 root 守护进程（MacEasyTierHelper）通信的客户端 + 一次性安装/卸载。
///
/// 守护进程只需授权安装一次（管理员密码），之后 TUN 网络的启动/停止都是一次本地 socket 往返，
/// 不再弹窗，也不再经过 `sh -c` / 轮询 pid 文件。
enum PrivilegedHelper {
    static let label = "com.maceasytier.helper"
    static let protocolVersion = 2
    static let socketPath = "/var/run/com.maceasytier.helper.sock"
    static let installDirectory = "/Library/PrivilegedHelperTools/com.maceasytier.helper"
    static let plistPath = "/Library/LaunchDaemons/com.maceasytier.helper.plist"
    static var installedCorePath: String { installDirectory + "/easytier-core" }
    static var installedHelperPath: String { installDirectory + "/MacEasyTierHelper" }

    struct HelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct CoreInfo: Sendable, Equatable {
        var id: String
        var pid: Int32
        var footprint: UInt64
        var started: Date
    }

    struct ExitInfo: Sendable, Equatable {
        var id: String
        var status: Int
        var when: Date
    }

    struct Status: Sendable {
        var protocolVersion: Int
        var tag: String
        var cores: [CoreInfo] = []
        var exits: [ExitInfo] = []
    }

    // MARK: - Socket client（阻塞调用，必须在后台线程使用）

    /// 发送一行请求（TAB 分隔），读取到 EOF 为止，返回按行拆分的应答。
    static func send(_ fields: [String], timeout: TimeInterval = 3, socketPath: String = socketPath) throws -> [[String]] {
        let request = fields.joined(separator: "\t") + "\n"
        guard !fields.contains(where: { $0.contains("\n") }) else {
            throw HelperError(message: "请求包含非法字符。")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HelperError(message: "socket 路径过长。")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HelperError(message: "无法创建 socket。") }
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw HelperError(message: "系统服务未运行。")
        }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw HelperError(message: "发送失败：\(String(cString: strerror(errno)))")
            }
            sent += written
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperError(message: errno == EAGAIN ? "系统服务响应超时。" : "读取失败：\(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            response.append(contentsOf: chunk[..<count])
            if response.count > 1 << 20 { break }
        }

        let text = String(decoding: response, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        guard let first = lines.first, let head = first.first else {
            throw HelperError(message: "系统服务无应答。")
        }
        if head == "ERR" {
            throw HelperError(message: first.dropFirst().joined(separator: " "))
        }
        return lines
    }

    static func status(socketPath: String = socketPath) throws -> Status {
        let lines = try send(["STATUS"], timeout: 2, socketPath: socketPath)
        guard let head = lines.first, head.count >= 3, head[0] == "OK" else {
            throw HelperError(message: "系统服务应答无效。")
        }
        var status = Status(protocolVersion: Int(head[1]) ?? 0, tag: head[2])
        for fields in lines.dropFirst() {
            switch fields.first {
            case "CORE" where fields.count >= 5:
                status.cores.append(CoreInfo(
                    id: fields[1],
                    pid: Int32(fields[2]) ?? 0,
                    footprint: UInt64(fields[3]) ?? 0,
                    started: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0)
                ))
            case "EXIT" where fields.count >= 4:
                status.exits.append(ExitInfo(
                    id: fields[1],
                    status: Int(fields[2]) ?? 0,
                    when: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)
                ))
            default:
                break
            }
        }
        return status
    }

    static func startCore(
        id: UUID,
        rpcPort: Int,
        ownerPID: Int32,
        logLevel: String,
        compression: String,
        configPath: String,
        logPath: String,
        socketPath: String = socketPath
    ) throws -> Int32 {
        let lines = try send(
            [
                "START", id.uuidString, String(rpcPort), String(ownerPID), logLevel,
                compression == "none" || compression.isEmpty ? "-" : compression,
                configPath, logPath,
            ],
            timeout: 5,
            socketPath: socketPath
        )
        guard let head = lines.first, head.count >= 2, head[0] == "OK", let pid = Int32(head[1]) else {
            throw HelperError(message: "系统服务应答无效。")
        }
        return pid
    }

    static func stopCore(id: UUID, socketPath: String = socketPath) throws {
        _ = try send(["STOP", id.uuidString], timeout: 5, socketPath: socketPath)
    }

    static func stopAll(socketPath: String = socketPath) throws {
        _ = try send(["STOPALL"], timeout: 2, socketPath: socketPath)
    }

    // MARK: - 安装 / 卸载

    /// 期望的守护进程版本标记：helper 与 core 二进制内容的哈希。内容变化（App 升级）后会触发“需要更新”。
    static func expectedTag(helper: URL, core: URL) -> String? {
        guard let helperData = try? Data(contentsOf: helper, options: .mappedIfSafe),
              let coreData = try? Data(contentsOf: core, options: .mappedIfSafe) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("proto\(protocolVersion)".utf8))
        hasher.update(data: helperData)
        hasher.update(data: coreData)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func install(helper: URL, core: URL, tag: String) async throws {
        guard let helperHash = sha256(of: helper), let coreHash = sha256(of: core) else {
            throw HelperError(message: "无法读取 helper/core 二进制。")
        }
        let directory = installDirectory
        let uid = getuid()
        let arguments = [
            directory + "/MacEasyTierHelper", "--socket", socketPath,
            "--core", directory + "/easytier-core", "--uid", String(uid), "--tag", tag,
        ]

        // 复制 -> 校验哈希 -> 才加载。校验在 root 拥有的目标文件上做，避免复制期间源文件被替换。
        var script = [
            "set -e",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/mkdir -p \(q(directory))",
            "/bin/cp -f \(q(helper.path)) \(q(directory + "/MacEasyTierHelper"))",
            "/bin/cp -f \(q(core.path)) \(q(directory + "/easytier-core"))",
            "/usr/sbin/chown -R root:wheel \(q(directory))",
            "/bin/chmod 755 \(q(directory)) \(q(directory + "/MacEasyTierHelper")) \(q(directory + "/easytier-core"))",
            "[ \"$(/usr/bin/shasum -a 256 \(q(directory + "/MacEasyTierHelper")) | /usr/bin/cut -d' ' -f1)\" = \(q(helperHash)) ] || { echo 'helper hash mismatch' >&2; exit 41; }",
            "[ \"$(/usr/bin/shasum -a 256 \(q(directory + "/easytier-core")) | /usr/bin/cut -d' ' -f1)\" = \(q(coreHash)) ] || { echo 'core hash mismatch' >&2; exit 42; }",
        ]
        let plistLines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
            "    <key>Label</key><string>\(label)</string>",
            "    <key>ProgramArguments</key>",
            "    <array>",
        ] + arguments.map { "        <string>\($0)</string>" } + [
            "    </array>",
            "    <key>RunAtLoad</key><true/>",
            "    <key>KeepAlive</key><true/>",
            "    <key>ProcessType</key><string>Interactive</string>",
            "    <key>StandardErrorPath</key><string>/var/log/\(label).log</string>",
            "    <key>StandardOutPath</key><string>/var/log/\(label).log</string>",
            "</dict>",
            "</plist>",
        ]

        script.append("/usr/bin/printf '%s\\n' " + plistLines.map(q).joined(separator: " ") + " > \(q(plistPath))")
        script += [
            "/usr/sbin/chown root:wheel \(q(plistPath))",
            "/bin/chmod 644 \(q(plistPath))",
            "/bin/launchctl bootstrap system \(q(plistPath))",
        ]
        try await runPrivileged(script.joined(separator: "\n"), prompt: "MacEasyTier 需要安装一次系统服务，以便无需反复输入密码即可启动/停止 TUN 网络。")
    }

    static func uninstall() async throws {
        let script = [
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/rm -f \(q(plistPath)) \(q(socketPath)) \(q("/var/log/\(label).log"))",
            "/bin/rm -rf \(q(installDirectory))",
        ].joined(separator: "\n")
        try await runPrivileged(script, prompt: "MacEasyTier 将卸载系统服务。")
    }

    /// 以管理员权限执行 shell 脚本（标准系统密码框）。用户取消时抛出 `HelperError(message: "已取消")`。
    static func runPrivileged(_ script: String, prompt: String) async throws {
        let literal = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let promptLiteral = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(literal)\" with prompt \"\(promptLiteral)\" with administrator privileges"

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if message.contains("-128") || message.localizedCaseInsensitiveContains("canceled") {
                    throw HelperError(message: "已取消管理员授权。")
                }
                throw HelperError(message: message.isEmpty ? "管理员命令失败（\(process.terminationStatus)）。" : message)
            }
        }.value
    }

    private static func q(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
