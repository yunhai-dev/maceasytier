import Foundation
import Observation

/// 网络配置的持久化与增删改查。密钥不入库，统一走 Keychain。
@MainActor
@Observable
final class NetworkStore {
    var groups: [NetworkGroup] = []
    var profiles: [NetworkProfile] = []
    var logLevel: String = "info"
    var showInspector: Bool = true
    var lastError: String?

    init() {
        load()
    }

    func load() {
        AppPaths.ensureDirectories()
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else {
            if !FileManager.default.fileExists(atPath: AppPaths.stateFile.path) {
                save()
            }
            return
        }

        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            groups = state.groups
            profiles = state.profiles
            logLevel = state.logLevel
            showInspector = state.showInspector
        } catch {
            lastError = "无法读取已保存的网络：\(error.localizedDescription)"
        }
    }

    func save() {
        AppPaths.ensureDirectories()
        let state = PersistedState(
            groups: groups,
            profiles: profiles,
            logLevel: logLevel,
            showInspector: showInspector
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: AppPaths.stateFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.stateFile.path)
            lastError = nil
        } catch {
            lastError = "无法保存网络：\(error.localizedDescription)"
        }
    }

    func profile(id: UUID) -> NetworkProfile? {
        profiles.first { $0.id == id }
    }

    func addGroup(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups.append(NetworkGroup(name: trimmed, isManual: true))
        save()
    }

    func renameGroup(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        save()
    }

    func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for index in profiles.indices where profiles[index].groupID == id {
            profiles[index].groupID = nil
        }
        save()
    }

    func secret(for id: UUID) -> String {
        SecretStore.secret(for: id) ?? ""
    }

    func setSecret(_ secret: String, for id: UUID) {
        if secret.isEmpty {
            SecretStore.deleteSecret(for: id)
        } else if !SecretStore.setSecret(secret, for: id) {
            lastError = "无法将网络密钥保存到钥匙串。"
        }
    }

    @discardableResult
    func addProfile(_ profile: NetworkProfile, secret: String) -> NetworkProfile {
        profiles.append(profile)
        setSecret(secret, for: profile.id)
        save()
        return profile
    }

    func updateProfile(_ profile: NetworkProfile, secret: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let updated = Self.reconciled(profile, previous: profiles[index])
        profiles[index] = updated
        setSecret(secret, for: profile.id)
        save()
    }

    /// 编辑器里的副本可能带着旧租约；租约由运行时维护，只有网络标识变化时才作废。
    nonisolated static func reconciled(_ updated: NetworkProfile, previous: NetworkProfile) -> NetworkProfile {
        var result = updated
        let identityChanged = previous.config.networkName != updated.config.networkName
            || previous.config.dhcp != updated.config.dhcp
            || previous.config.publicServer != updated.config.publicServer
            || previous.config.peers != updated.config.peers
        result.leasedIPv4 = identityChanged ? nil : previous.leasedIPv4
        return result
    }

    /// 记录/作废 DHCP 租约（虚拟 IP）。nil 表示作废。
    func setLease(_ ip: String?, for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].leasedIPv4 != ip else { return }
        profiles[index].leasedIPv4 = ip
        save()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        SecretStore.deleteSecret(for: id)
        try? FileManager.default.removeItem(at: AppPaths.networkDirectory(for: id))
        save()
    }

    @discardableResult
    func duplicateProfile(id: UUID) -> NetworkProfile? {
        guard let source = profile(id: id) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " Copy"
        copy.isFavorite = false
        copy.autoConnect = false
        copy.leasedIPv4 = nil
        profiles.append(copy)
        setSecret(secret(for: id), for: copy.id)
        save()
        return copy
    }

    func visibleProfiles(selection: SidebarItem, searchText: String) -> [NetworkProfile] {
        var rows: [NetworkProfile]
        switch selection {
        case .overview:
            rows = []
        case .all:
            rows = profiles
        case .favorites:
            rows = profiles.filter(\.isFavorite)
        case let .group(id):
            rows = profiles.filter { $0.groupID == id }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.config.networkName.localizedCaseInsensitiveContains(query)
                || $0.config.hostname.localizedCaseInsensitiveContains(query)
        }
    }

    private struct PersistedState: Codable {
        var groups: [NetworkGroup]
        var profiles: [NetworkProfile]
        var logLevel: String
        var showInspector: Bool
    }
}
