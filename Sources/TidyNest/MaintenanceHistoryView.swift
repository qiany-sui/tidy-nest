import SwiftUI
import TidyNestProtocol

struct MaintenanceHistoryView: View {
    @Bindable var model: WorkspaceModel
    @State private var selectedID: String?
    private var maintenance: MaintenanceModel { model.maintenance }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("操作记录").font(.system(size: 28, weight: .semibold))
                    Text("查看本机维护结果，以及每个项目的去向。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { maintenance.reloadHistory() } label: { Label("刷新记录", systemImage: "arrow.clockwise") }
                    .controlSize(.large).disabled(!maintenance.canStart)
            }.padding(28)
            Divider()
            if maintenance.historyPhase == .loaded {
                if maintenance.history.isEmpty {
                    NestEmptyState(symbol: "clock.arrow.circlepath", title: "还没有操作记录", message: "执行后的本地记录会显示在这里。")
                } else {
                    HSplitView {
                        List(selection: $selectedID) {
                            ForEach(maintenance.history) { result in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(result.title).font(.headline).lineLimit(2)
                                    HStack {
                                        Text(result.status.displayTitle).foregroundStyle(result.status == .completed ? NestStyle.green : .secondary)
                                        Spacer()
                                        Text(result.finishedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                                    }.font(.caption)
                                }.padding(.vertical, 10).tag(result.runID)
                            }
                        }.listStyle(.inset).frame(minWidth: 280, idealWidth: 320)
                        if let result = maintenance.history.first(where: { $0.runID == selectedID }) {
                            MaintenanceResultView(result: result, reveal: model.reveal).frame(minWidth: 390)
                        } else {
                            NestEmptyState(symbol: "doc.text", title: "查看执行结果", message: "选择一条操作记录。")
                        }
                    }
                }
            } else {
                QueryStatusView(phase: maintenance.historyPhase, idleTitle: "本地操作记录", idleMessage: "点击刷新读取本机维护记录。", symbol: "clock.arrow.circlepath", cancel: maintenance.cancel)
            }
        }.task { if maintenance.historyPhase == .idle { maintenance.reloadHistory() } }
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
