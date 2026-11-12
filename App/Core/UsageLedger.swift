import Foundation
import Observation

/// 跨会话累计流量，供首页“总下载/总上传”展示。
@MainActor
@Observable
final class UsageLedger {
    var totalRx: UInt64 = 0
    var totalTx: UInt64 = 0
    var todayRx: UInt64 = 0
    var todayTx: UInt64 = 0
    var monthRx: UInt64 = 0
    var monthTx: UInt64 = 0

    private var dayKey = ""
    private var monthKey = ""
    private var lastRx: UInt64?
    private var lastTx: UInt64?
    private var lastSave = Date.distantPast

    init() {
        load()
        rollPeriodsIfNeeded()
    }

    func update(rx: UInt64, tx: UInt64) {
        rollPeriodsIfNeeded()

        if let previousRx = lastRx, let previousTx = lastTx {
            if rx >= previousRx, tx >= previousTx {
                let deltaRx = rx - previousRx
                let deltaTx = tx - previousTx
                totalRx += deltaRx
                totalTx += deltaTx
                todayRx += deltaRx
                todayTx += deltaTx
                monthRx += deltaRx
                monthTx += deltaTx
            }
        }
        lastRx = rx
        lastTx = tx
        saveIfNeeded()
    }

    func flush() {
        save()
    }

    private func rollPeriodsIfNeeded() {
        let now = Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let newDay = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let newMonth = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)

        if monthKey != newMonth {
            monthKey = newMonth
            monthRx = 0
            monthTx = 0
        }
        if dayKey != newDay {
            dayKey = newDay
            todayRx = 0
            todayTx = 0
        }
    }

    private func saveIfNeeded() {
        guard Date().timeIntervalSince(lastSave) > 10 else { return }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        totalRx = state.totalRx
        totalTx = state.totalTx
        todayRx = state.todayRx
        todayTx = state.todayTx
        monthRx = state.monthRx
        monthTx = state.monthTx
        dayKey = state.dayKey
        monthKey = state.monthKey
    }

    private func save() {
        rollPeriodsIfNeeded()
        let state = PersistedState(
            totalRx: totalRx,
            totalTx: totalTx,
            todayRx: todayRx,
            todayTx: todayTx,
            monthRx: monthRx,
            monthTx: monthTx,
            dayKey: dayKey,
            monthKey: monthKey
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
            lastSave = Date()
        } catch {
            return
        }
    }

    private static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("usage.json")
    }

    private struct PersistedState: Codable {
        var totalRx: UInt64
        var totalTx: UInt64
        var todayRx: UInt64
        var todayTx: UInt64
        var monthRx: UInt64
        var monthTx: UInt64
        var dayKey: String
        var monthKey: String
    }
}
