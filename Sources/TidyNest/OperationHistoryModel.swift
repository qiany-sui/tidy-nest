import Foundation
import Observation
import TidyNestCore
import TidyNestProtocol

@MainActor @Observable
final class OperationHistoryModel {
    private var snapshot = OperationHistorySnapshot()
    private var hasLoaded: Bool
    private(set) var notice: String?
    @ObservationIgnored private let store: OperationHistoryStore?

    init(store: OperationHistoryStore? = nil) {
        self.store = store
        hasLoaded = store == nil
    }

    var records: [OperationRecord] {
        snapshot.records.sorted { $0.finishedAt == $1.finishedAt ? $0.id < $1.id : $0.finishedAt > $1.finishedAt }
    }
    var canDelete: Bool { hasLoaded }

    func load() {
        guard !hasLoaded else { return }
        do {
            let sessionRecords = snapshot.records
            snapshot = try store?.load() ?? OperationHistorySnapshot()
            hasLoaded = true
            notice = nil
            merge(sessionRecords)
            if !sessionRecords.isEmpty { persist() }
        } catch {
            notice = "本地操作记录无法读取，已保留原文件。本次新增记录暂存于当前会话。\(error.localizedDescription)"
        }
    }

    func record(_ record: OperationRecord) {
        load()
        merge([record])
        persist()
    }

    func mergeExecutions(_ results: [MaintenanceResult]) {
        load()
        let previous = snapshot
        merge(results.map { OperationRecord(execution: $0) })
        if snapshot != previous { persist() }
    }

    @discardableResult
    func removeRecords(_ ids: Set<String>) -> Bool {
        load()
        guard canDelete else { return false }
        var next = snapshot
        let removed = next.records.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return true }
        for record in removed {
            if let runID = executionRunID(record) { next.deletedExecutionRunIDs.insert(runID) }
        }
        next.records.removeAll { ids.contains($0.id) }
        do {
            // 保存成功后再更新页面；仅处理确认时捕获的 ID，不扩大到后来新增的记录。
            try store?.save(next)
            snapshot = next
            notice = nil
            return true
        } catch {
            notice = "未能确认记录删除已保存，当前页面保留原记录。请重新打开后核对。\(error.localizedDescription)"
            return false
        }
    }

    private func merge(_ records: [OperationRecord]) {
        for record in records {
            if let runID = executionRunID(record), snapshot.deletedExecutionRunIDs.contains(runID) { continue }
            if let index = snapshot.records.firstIndex(where: { $0.id == record.id }) { snapshot.records[index] = record }
            else { snapshot.records.append(record) }
        }
    }

    private func executionRunID(_ record: OperationRecord) -> String? {
        guard record.kind == .execution else { return nil }
        if let result = record.execution { return result.runID }
        return record.id.hasPrefix("execution:") ? String(record.id.dropFirst("execution:".count)) : nil
    }

    private func persist() {
        guard hasLoaded else { return }
        do {
            try store?.save(snapshot)
            notice = nil
        } catch {
            notice = "操作结果已显示，但记录未能保存；本次新增记录暂存于当前会话。\(error.localizedDescription)"
        }
    }
}

struct OperationActivity {
    let id = UUID().uuidString
    let kind: OperationKind
    let title: String
    let targetPath: String?
    let startedAt = Date()

    func finished(_ status: MaintenanceStatus, summary: String, executionRunID: String? = nil) -> OperationRecord {
        OperationRecord(id: executionRunID.map { "execution:\($0)" } ?? id, kind: kind, status: status, title: title, targetPath: targetPath, startedAt: startedAt, summary: summary)
    }
}
