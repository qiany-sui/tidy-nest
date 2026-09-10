import SwiftUI
import TidyNestCore
import TidyNestProtocol

struct MaintenanceHistoryView: View {
    @Bindable var model: WorkspaceModel
    @State private var selectedID: String?
    @State private var deletion: HistoryDeletion?
    private var maintenance: MaintenanceModel { model.maintenance }
    private var history: OperationHistoryModel { model.operationHistory }
    private var records: [OperationRecord] { history.records }
    private var selectedRecord: OperationRecord? { records.first { $0.id == selectedID } }
    private var canDelete: Bool { !model.isTerminating && !maintenance.isExecuting && history.canDelete }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("操作记录").font(.system(size: 28, weight: .semibold))
                    Text("查看应用刷新、磁盘读取、计划检查与移除的结果。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { maintenance.reloadHistory() } label: { Label("刷新记录", systemImage: "arrow.clockwise") }
                    .controlSize(.large).disabled(!maintenance.canReloadHistory)
            }.padding(28)
            Divider()
            HStack(spacing: 16) {
                Text("\(records.count) 条记录").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("删除所选记录…") {
                    if let selectedRecord { deletion = HistoryDeletion(records: [selectedRecord], all: false) }
                }.disabled(!canDelete || selectedRecord == nil)
                Button("清空记录…") {
                    deletion = HistoryDeletion(records: records, all: true)
                }.disabled(!canDelete || records.isEmpty)
            }.padding(.horizontal, 28).padding(.vertical, 12)
            if let notice = history.notice { historyNotice(notice) }
            if case .failed(let message) = maintenance.historyPhase {
                historyNotice("移除记录读取失败，已保留当前记录。\(message)")
            } else if maintenance.historyPhase == .loading || maintenance.historyPhase == .cancelling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(maintenance.historyPhase == .cancelling ? "正在取消读取…" : "正在读取移除记录…").font(.caption)
                    Spacer()
                    Button("取消", action: maintenance.cancelHistory).disabled(maintenance.historyPhase == .cancelling)
                }.padding(.horizontal, 28).padding(.bottom, 12)
            } else if maintenance.historyPhase == .cancelled {
                historyNotice("读取已取消，当前记录仍可查看。")
            }
            Divider()
            if records.isEmpty {
                NestEmptyState(symbol: "clock.arrow.circlepath", title: "还没有操作记录",
                               message: "刷新应用、读取文件夹或检查计划后，结果会显示在这里。此前未记录的查询不会补录。")
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.title).font(.headline).lineLimit(2)
                                HStack {
                                    Text(record.kind.displayTitle)
                                    Spacer(minLength: 8)
                                    Text(record.statusTitle).foregroundStyle(record.status == .completed ? NestStyle.green : .secondary)
                                }.font(.caption)
                                Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 10).tag(record.id)
                        }
                    }.listStyle(.inset).frame(minWidth: 280, idealWidth: 340)
                    // 分栏宿主保持不变，空态和详情切换不重新分配宽度。
                    GeometryReader { geometry in
                        Group {
                            if let record = selectedRecord {
                                if let result = record.execution {
                                    MaintenanceResultView(result: result, reveal: model.reveal)
                                } else {
                                    OperationRecordDetail(record: record)
                                }
                            } else {
                                NestEmptyState(symbol: "doc.text", title: "查看操作详情", message: "选择一条操作记录。")
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(minWidth: 390, idealWidth: 440)
                }
            }
        }
        .task {
            history.load()
            if maintenance.historyPhase == .idle { maintenance.reloadHistory() }
        }
        .onChange(of: records.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .alert(deletion?.title ?? "删除操作记录", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { pending in
            Button("取消", role: .cancel) { deletion = nil }
            Button(pending.all ? "清空记录" : "删除记录", role: .destructive) {
                guard canDelete else { return }
                history.removeRecords(Set(pending.records.map(\.id)))
                deletion = nil
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    private func historyNotice(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 12)
    }
}

private struct HistoryDeletion {
    let records: [OperationRecord]
    let all: Bool
    var title: String { all ? "清空这 \(records.count) 条记录？" : "删除这条操作记录？" }
    var message: String {
        let subject = all ? "将删除当前页面中的 \(records.count) 条记录。" : "将删除“\(records.first?.title ?? "")”的记录。"
        let recovery = records.contains { $0.kind == .execution } ? "移除记录中的原路径和恢复位置也将从此页面移除。" : ""
        return "\(subject)不会改动应用、原文件或废纸篓中的内容。\(recovery)此操作无法撤销。"
    }
}

private struct OperationRecordDetail: View {
    let record: OperationRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: record.kind.symbol)
                        .font(.system(size: 30, weight: .light)).foregroundStyle(NestStyle.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title).font(.title2.weight(.semibold))
                        Text("\(record.kind.displayTitle) · \(record.statusTitle)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(record.summary).font(.callout).textSelection(.enabled)
                if let path = record.targetPath {
                    DetailField(label: "位置", value: path)
                }
                DetailField(label: "开始时间", value: record.startedAt.formatted(date: .abbreviated, time: .standard))
                DetailField(label: "结束时间", value: record.finishedAt.formatted(date: .abbreviated, time: .standard))
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension OperationKind {
    var displayTitle: String {
        switch self {
        case .applicationList: "应用列表"
        case .applicationRefresh: "单个应用刷新"
        case .diskAnalysis: "磁盘读取"
        case .cleanScan: "清理检查"
        case .uninstallPlan: "移除计划检查"
        case .execution: "移入废纸篓"
        }
    }
    var symbol: String {
        switch self {
        case .applicationList, .applicationRefresh: "arrow.clockwise"
        case .diskAnalysis: "internaldrive"
        case .cleanScan, .uninstallPlan: "checklist"
        case .execution: "trash"
        }
    }
}

private extension OperationRecord {
    var statusTitle: String {
        guard kind != .execution else { return status.displayTitle }
        switch status {
        case .completed: return "已完成"
        case .partial: return "检查不完整"
        case .cancelled: return "已取消"
        case .blocked: return "已保留"
        case .failed: return "失败"
        case .unknown: return "结果待核对"
        }
    }
}

struct MaintenanceResultView: View {
    let result: MaintenanceResult
    let reveal: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: result.status == .completed ? "checkmark.circle" : "info.circle")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(NestStyle.green)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.status.displayTitle).font(.title2.weight(.semibold))
                        Text(result.title).font(.callout).foregroundStyle(.secondary)
                        Text(result.finishedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = result.message { Text(message).font(.callout).textSelection(.enabled) }
                HStack(alignment: .top, spacing: 30) {
                    DetailField(label: "选中项目的已知占用", value: formattedBytes(result.selectedBytes))
                    DetailField(label: "已移入废纸篓的原占用", value: formattedBytes(result.trashedBytes))
                }
                Text("移入废纸篓不会立即释放磁盘空间。如需恢复，请按操作记录中的原路径手动移回。以下位置与状态来自本次执行记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if let delta = result.freeBytesDelta {
                    DetailField(label: "记录到的卷可用空间变化", value: ByteCountFormatter.string(fromByteCount: delta, countStyle: .file))
                }
                Divider()
                if result.items.isEmpty {
                    Text("没有逐项处理记录。请以上方状态和说明为准。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(result.items) { item in
                    MaintenanceResultRow(item: item, reveal: reveal)
                    Divider()
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MaintenanceResultRow: View {
    let item: MaintenanceItemResult
    let reveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(item.outcome.displayTitle).font(.caption).foregroundStyle(item.outcome == .trashed ? NestStyle.green : .secondary)
            }
            Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let reason = item.reason { Text(reason).font(.caption).textSelection(.enabled) }
            if let path = item.trashPath {
                resultLocation("废纸篓位置", path: path)
            }
            if let path = item.retainedPath {
                resultLocation("保留位置，请核对", path: path)
            }
        }.padding(.vertical, 8)
    }

    private func resultLocation(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示\(title)")
            }
        }
    }
}

extension MaintenanceStatus {
    var displayTitle: String {
        switch self {
        case .completed: "已完成"
        case .partial: "部分完成"
        case .cancelled: "已取消剩余操作"
        case .blocked: "操作被阻止"
        case .failed: "执行失败"
        case .unknown: "结果待核对"
        }
    }
}

extension ItemOutcome {
    var displayTitle: String {
        switch self {
        case .trashed: "已移入废纸篓"
        case .skipped: "已保留"
        case .failed: "处理失败"
        case .cancelled: "已取消"
        case .unknown: "待核对"
        }
    }
}
