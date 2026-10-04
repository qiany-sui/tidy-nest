import Foundation
import Observation
import TidyNestCore
import TidyNestProtocol

@MainActor @Observable
final class OperationHistoryModel {
    private var snapshot = OperationHistorySnapshot()
    private var hasLoaded: Bool
    private(set) var notice: String?
    private(set) var isLoading = false
    var selectedRecordID: String?
    private var pendingDeletions = 0
    @ObservationIgnored private let storage: OperationHistoryStorage
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceGeneration = 0

    init(store: OperationHistoryStore? = nil) {
        storage = OperationHistoryStorage(store: store)
        hasLoaded = store == nil
    }

    var records: [OperationRecord] {
        snapshot.records.sorted { $0.finishedAt == $1.finishedAt ? $0.id < $1.id : $0.finishedAt > $1.finishedAt }
    }
    var canDelete: Bool { hasLoaded && pendingDeletions == 0 }

    func load() {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        enqueue { await self.loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let saved = try await storage.load()
            // 等待读取期间也可能收到新结果，合并返回时的会话内容。
            let sessionRecords = snapshot.records
            snapshot = saved
            hasLoaded = true
            notice = nil
            merge(sessionRecords)
            // 原文件恢复可读后，把此前因读取失败暂存的会话结果一并落盘。
            if snapshot != saved { await persist() }
        } catch {
            notice = "本地操作记录无法读取，已保留原文件。本次新增记录暂存于当前会话。\(error.localizedDescription)"
        }
    }

    func record(_ record: OperationRecord) {
        merge([record])
        enqueue {
            await self.loadIfNeeded()
            await self.persist()
        }
    }

    func mergeExecutions(_ results: [MaintenanceResult]) {
        let previous = snapshot
        merge(results.map { OperationRecord(execution: $0) })
        if snapshot != previous {
            enqueue {
                await self.loadIfNeeded()
                await self.persist()
            }
        } else { load() }
    }

    @discardableResult
    func removeRecords(_ ids: Set<String>) async -> Bool {
        pendingDeletions += 1
        let previous = persistenceTask
        persistenceGeneration += 1
        let deletion = Task { @MainActor in
            await previous?.value
            await self.loadIfNeeded()
            let removed = await self.removeLoadedRecords(ids)
            self.pendingDeletions -= 1
            return removed
        }
        persistenceTask = Task { _ = await deletion.value }
        return await deletion.value
    }

    private func removeLoadedRecords(_ ids: Set<String>) async -> Bool {
        guard hasLoaded else { return false }
        var next = snapshot
        let removed = next.records.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return true }
        for record in removed {
            if let runID = executionRunID(record) { next.deletedExecutionRunIDs.insert(runID) }
        }
        next.records.removeAll { ids.contains($0.id) }
        do {
            // 保存成功后再更新页面；仅处理确认时捕获的 ID，不扩大到后来新增的记录。
            try await storage.save(next)
            // 保存过程中新增的记录仍在会话里，只移除确认时捕获的 ID。
            snapshot.records.removeAll { ids.contains($0.id) }
            snapshot.deletedExecutionRunIDs.formUnion(next.deletedExecutionRunIDs)
            if let selectedRecordID, ids.contains(selectedRecordID) { self.selectedRecordID = nil }
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

    private func persist() async {
        guard hasLoaded else { return }
        do {
            try await storage.save(snapshot)
            notice = nil
        } catch {
            notice = "操作结果已显示，但记录未能保存；本次新增记录暂存于当前会话。\(error.localizedDescription)"
        }
    }

    private func enqueue(_ action: @escaping @MainActor () async -> Void) {
        let previous = persistenceTask
        persistenceGeneration += 1
        persistenceTask = Task { @MainActor in
            await previous?.value
            await action()
        }
    }

    func waitForPersistence() async {
        // 等待期间可能有其他只读任务完成；调用者取消也不取消已排队的保存。
        while true {
            let generation = persistenceGeneration
            await persistenceTask?.value
            if generation == persistenceGeneration { return }
        }
    }
}

private final class OperationHistoryStorage: Sendable {
    private let store: OperationHistoryStore?
    private let queue = DispatchQueue(label: "TidyNest.operation-history", qos: .utility)

    init(store: OperationHistoryStore?) { self.store = store }

    func load() async throws -> OperationHistorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [store] in
                do { continuation.resume(returning: try store?.load() ?? OperationHistorySnapshot()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func save(_ snapshot: OperationHistorySnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [store] in
                do { try store?.save(snapshot); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
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
