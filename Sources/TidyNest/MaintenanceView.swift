import SwiftUI
import TidyNestProtocol

struct MaintenanceView: View {
    @Bindable var model: WorkspaceModel
    @State private var showForceEnd = false
    private var maintenance: MaintenanceModel { model.maintenance }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(maintenance.plan?.kind == .uninstall ? "应用移除计划" : "清理").font(.system(size: 28, weight: .semibold))
                    Text("先看清每一项，再决定哪些移入废纸篓。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Button { maintenance.scanClean() } label: { Label("扫描缓存与日志", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!maintenance.canStart)
            }.padding(28)
            Divider()
            if let notice = maintenance.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(NestStyle.green.opacity(0.07))
            }
            content
        }
        .sheet(item: Binding(get: { maintenance.confirmation }, set: { if $0 == nil { maintenance.dismissConfirmation() } })) { confirmation in
            MaintenanceConfirmationView(confirmation: confirmation, cancel: maintenance.dismissConfirmation, confirm: maintenance.confirmExecution)
        }
        .alert("强制结束当前任务？", isPresented: $showForceEnd) {
            Button("继续等待", role: .cancel) {}
            Button("强制结束并稍后核对", role: .destructive) { maintenance.forceEndConfirmed() }
        } message: {
            Text("已经移入废纸篓的项目不会撤回。未收到完整结果的项目可能需要在操作记录及 Finder 中核对。")
        }
    }

    @ViewBuilder private var content: some View {
        if maintenance.isExecuting || maintenance.phase == .scanning || (maintenance.phase == .cancelling && maintenance.plan == nil) {
            progress
        } else if let result = maintenance.result {
            MaintenanceResultView(result: result, reveal: model.reveal)
        } else if maintenance.executionUncertain {
            NestEmptyState(symbol: "questionmark.circle", title: "本次结果待核对", message: failureMessage)
        } else if let plan = maintenance.plan {
            planContent(plan)
        } else {
            switch maintenance.phase {
            case .failed(let message):
                NestEmptyState(symbol: "exclamationmark.circle", title: "未能完成检查", message: message)
            case .cancelled:
                NestEmptyState(symbol: "pause.circle", title: "检查已取消", message: "没有执行移除操作，可以随时重新扫描。")
            default:
                NestEmptyState(symbol: "sparkles", title: "给空间一点余地", message: "主动扫描可识别应用的缓存与日志。所有候选默认不勾选，扫描不会移除文件。")
            }
        }
    }

    private var failureMessage: String {
        if case .failed(let message) = maintenance.phase { return message }
        return "请在操作记录中检查已处理项目及保留位置。"
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: maintenance.isExecuting ? "trash" : "doc.text.magnifyingglass")
                        .font(.system(size: 22)).foregroundStyle(NestStyle.green)
                        .frame(width: 44, height: 44)
                        .background(NestStyle.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    Text(maintenance.phase == .cancelling ? "正在等待任务收尾" : (maintenance.isExecuting ? "正在移入废纸篓" : "正在检查候选文件"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if maintenance.phase == .cancelling {
                        Button("强制结束…") { showForceEnd = true }
                    } else {
                        Button(maintenance.isExecuting ? "取消剩余操作" : "取消检查") { maintenance.cancel() }
                    }
                }
                Text(maintenance.progressMessage).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
                ProgressView(value: maintenance.executionProgress)
                    .progressViewStyle(.linear).controlSize(.large).tint(NestStyle.green)
                    .accessibilityLabel(maintenance.isExecuting ? "所选项目处理进度" : "检查进度")
                if maintenance.isExecuting {
                    HStack {
                        Text("已处理 \(maintenance.processedItemCount) / \(maintenance.selectedItemIDs.count) 项").monospacedDigit()
                        Spacer()
                        if maintenance.processedItemCount == maintenance.selectedItemIDs.count {
                            Text("正在等待最终结果…")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(maintenance.phase == .cancelling ? "任务收尾后，可以重新开始检查。" : "检查完成后会显示计划，供你逐项核对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading)
            .background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 16))
            if maintenance.isExecuting {
                Text("取消会停止剩余操作，并等待当前项目完成或保留。已发生的结果会显示在这里。")
                    .font(.caption).foregroundStyle(.secondary)
                List(maintenance.itemResults) { item in MaintenanceResultRow(item: item, reveal: model.reveal) }
                    .listStyle(.inset)
            } else { Spacer() }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func planContent(_ plan: MaintenancePlan) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.title).font(.headline)
                    Text("检查时间：\(plan.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(plan.items.count) 个项目").font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 18)
            if !plan.scanComplete || maintenance.planExpired {
                Label(maintenance.planExpired ? "计划已失效，请重新扫描后再确认。" : "检查尚不完整，本计划不会执行。请查看下方原因。", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if !plan.scanIssues.isEmpty {
                DisclosureGroup("\(plan.scanIssues.count) 项检查提示") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(plan.scanIssues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.path).font(.caption).textSelection(.enabled)
                                Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.padding(.horizontal, 28).padding(.bottom, 12)
            }
            Divider()
            if plan.items.isEmpty {
                if plan.scanComplete {
                    NestEmptyState(symbol: "checkmark.shield", title: "没有可移除的项目", message: "本次检查没有找到符合当前规则的文件。")
                } else {
                    NestEmptyState(symbol: "exclamationmark.triangle", title: "未能完成检查", message: "本次检查尚未完成，无法确认是否有可移除的项目。请展开上方“检查提示”查看原因。")
                }
            } else {
                HSplitView {
                    planList.frame(minWidth: 320, idealWidth: 430)
                    planDetail.frame(minWidth: 285, idealWidth: 340)
                }
            }
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选 \(maintenance.selectedItemIDs.count) 项 · 已知占用 \(formattedBytes(maintenance.selectedBytes))").font(.callout.weight(.medium))
                    if maintenance.unknownSizeCount > 0 {
                        Text("另有 \(maintenance.unknownSizeCount) 项占用未知").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("移入废纸篓不会立即释放磁盘空间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("核对所选项目…") { maintenance.requestConfirmation() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!maintenance.canConfirm)
            }.padding(20)
        }
    }

    private var planList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或路径", text: Binding(get: { maintenance.searchText }, set: { maintenance.searchText = $0 }))
                    .textFieldStyle(.plain)
            }.padding(10).background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 8)).padding(16)
            HStack {
                Button("选择当前可选项目") {
                    for item in maintenance.filteredItems { maintenance.setSelected(item.itemID, selected: true) }
                }
                Button("取消可选项") {
                    for item in maintenance.filteredItems { maintenance.setSelected(item.itemID, selected: false) }
                }
                Spacer()
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 18).padding(.bottom, 10)
                .disabled(!maintenance.canStart || maintenance.planExpired)
            List(selection: Binding(get: { maintenance.focusedItemID }, set: { maintenance.focusedItemID = $0 })) {
                ForEach(PlanGroup.allCases) { group in
                    let items = maintenance.filteredItems.filter { PlanGroup.of($0) == group }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { item in
                                HStack(spacing: 10) {
                                    Toggle("选择 \(item.displayName)", isOn: Binding(get: { maintenance.selectedItemIDs.contains(item.itemID) }, set: { maintenance.setSelected(item.itemID, selected: $0) }))
                                        .labelsHidden().toggleStyle(.checkbox).disabled(!maintenance.canSelect(item))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(item.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if item.selection == .blocked {
                                            Text(item.blockedReason ?? "此项目受保护").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        } else if item.selection == .required {
                                            Text("应用本体 · 必选").font(.caption2).foregroundStyle(NestStyle.green)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Text(item.estimatedBytes.map(formattedBytes) ?? "未知").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 7).tag(item.itemID)
                            }
                        }
                    }
                }
            }.listStyle(.inset)
        }
    }

    @ViewBuilder private var planDetail: some View {
        if let item = maintenance.focusedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: item.kind == .application ? "app" : "doc").font(.system(size: 44, weight: .light)).foregroundStyle(NestStyle.green)
                    Text(item.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                    DetailField(label: "位置", value: item.path)
                    DetailField(label: "检查依据", value: item.reason)
                    DetailField(label: "操作影响", value: item.impact)
                    DetailField(label: "预计占用", value: item.estimatedBytes.map(formattedBytes) ?? "未知")
                    if let reason = item.blockedReason { DetailField(label: "保留原因", value: reason) }
                    if !item.dependsOnItemIDs.isEmpty {
                        Text("只有依赖项目确定移入废纸篓后，才会处理此项目。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.reveal(path: item.path) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                    Button { maintenance.changeProtection(path: item.path, protected: true) } label: { Label("长期保护此项目", systemImage: "shield") }
                        .disabled(!maintenance.canStart)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(NestStyle.subtle.opacity(0.5))
        } else {
            NestEmptyState(symbol: "checklist", title: "逐项核对", message: "选择一行查看路径、依据和影响。勾选框决定本次要移入废纸篓的项目。")
        }
    }
}

private enum PlanGroup: String, CaseIterable, Identifiable {
    case application, cache, logs, other
    var id: Self { self }
    var title: String { switch self { case .application: "应用本体"; case .cache: "缓存"; case .logs: "日志"; case .other: "其他检查项目" } }
    static func of(_ item: MaintenanceItem) -> Self {
        if item.kind == .application { return .application }
        if item.path.contains("/Library/Caches/") || item.ruleID.localizedCaseInsensitiveContains("cache") { return .cache }
        if item.path.contains("/Library/Logs/") || item.ruleID.localizedCaseInsensitiveContains("log") { return .logs }
        return .other
    }
}

private struct MaintenanceConfirmationView: View {
    let confirmation: MaintenanceConfirmation
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认移入废纸篓").font(.title2.weight(.semibold))
            Text("\(confirmation.title) · 共 \(confirmation.items.count) 项").font(.headline)
            Text("只处理下方列出的项目。文件会逐项移入废纸篓，不会立即释放磁盘空间；执行前还会重新检查文件及保护状态。如需恢复，请按操作记录中的原路径手动移回。")
                .font(.callout).foregroundStyle(.secondary)
            List(confirmation.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.displayName).fontWeight(.medium)
                        Spacer()
                        Text(item.estimatedBytes.map(formattedBytes) ?? "占用未知").foregroundStyle(.secondary)
                    }
                    Text(item.path).font(.caption).textSelection(.enabled)
                    Text(item.impact).font(.caption).foregroundStyle(.secondary)
                    if item.kind == .application { Text("应用本体为必选；相关文件依赖本体处理成功。").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }.listStyle(.inset)
            HStack {
                Text("已知占用 \(formattedBytes(confirmation.items.compactMap(\.estimatedBytes).reduce(0, +)))").font(.callout)
                if confirmation.items.contains(where: { $0.estimatedBytes == nil }) { Text("含占用未知项目").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("返回核对", action: cancel).keyboardShortcut(.cancelAction)
                Button("将这 \(confirmation.items.count) 项移入废纸篓", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 730, height: 560)
    }
}
