import AppKit
import SwiftUI
import TidyNestProtocol

struct MaintenanceView: View {
    @Bindable var model: WorkspaceModel
    @State private var showForceEnd = false
    @State private var showScanIssues = false
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
                if maintenance.plannedApplication != nil {
                    Button { maintenance.recheckApplication() } label: { Label("重新检查此应用", systemImage: "arrow.clockwise") }
                        .controlSize(.large).disabled(!maintenance.canScan)
                }
                Button { maintenance.scanClean() } label: { Label("扫描缓存与日志", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!maintenance.canScan)
            }.padding(28)
            Divider()
            if let notice = maintenance.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(NestStyle.green.opacity(0.07))
            }
            content
        }
        .onChange(of: maintenance.plan?.planID) { _, _ in showScanIssues = false }
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
                Text(maintenance.selectedItems.contains(where: { $0.requiresAuthorization == true }) ? "系统窗口打开时，请在该窗口完成授权或取消。此处取消会停止后续项目，并等待系统返回结果。" : "取消会停止剩余操作，并等待当前项目完成或保留。已发生的结果会显示在这里。")
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
                    if !plan.scanIssues.isEmpty {
                        Text("结果为检查时的状态；情况变化后，请重新检查。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(plan.items.count) 个项目").font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 18)
            if !plan.scanComplete || maintenance.planExpired {
                Label(maintenance.planExpired ? "计划已失效，请重新扫描后再确认。" : "检查尚不完整，本计划不会执行。请查看下方原因。", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if !plan.scanIssues.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showScanIssues.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showScanIssues ? 90 : 0))
                            Text("\(plan.scanIssues.count) 项检查提示")
                            Spacer()
                            Text(showScanIssues ? "收起" : "展开").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(plan.scanIssues.count) 项检查提示")
                    .accessibilityValue(showScanIssues ? "已展开" : "已收起")
                    if showScanIssues {
                        ViewThatFits(in: .vertical) {
                            scanIssuesContent(plan.scanIssues)
                            ScrollView { scanIssuesContent(plan.scanIssues) }
                        }.frame(maxHeight: 120)
                            // 避免父布局仍把短提示拉到高度上限。
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    private func scanIssuesContent(_ issues: [PlanIssue]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.path).font(.caption.weight(.medium)).textSelection(.enabled)
                    Text(issue.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var planList: some View {
        let isSearching = !maintenance.normalizedSearchText.isEmpty
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或路径", text: Binding(get: { maintenance.searchText }, set: { maintenance.searchText = $0 }))
                    .textFieldStyle(.plain)
            }.padding(10).background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 8)).padding(16)
            HStack {
                Button(isSearching ? "全选搜索结果" : "全选") {
                    maintenance.setFilteredItemsSelected(true)
                }
                Button(isSearching ? "取消搜索结果选择" : "取消全选") {
                    maintenance.setFilteredItemsSelected(false)
                }
                Spacer()
            }.font(.callout).buttonStyle(.bordered).controlSize(.regular).padding(.horizontal, 18).padding(.bottom, 10)
                .disabled(!maintenance.canStart || maintenance.planExpired)
            List(selection: Binding(get: { maintenance.focusedItemID }, set: { maintenance.focusedItemID = $0 })) {
                ForEach(PlanGroup.allCases) { group in
                    let items = maintenance.filteredItems.filter { PlanGroup.of($0) == group }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { item in
                                HStack(spacing: 10) {
                                    if item.selection == .blocked {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary).frame(width: 14)
                                            .accessibilityLabel("不可移除：" + (item.blockedReason ?? "此项目受保护"))
                                            .help(item.blockedReason ?? "此项目受保护")
                                    } else {
                                        Toggle("选择 \(item.displayName)", isOn: Binding(get: { maintenance.selectedItemIDs.contains(item.itemID) }, set: { maintenance.setSelected(item.itemID, selected: $0) }))
                                            .labelsHidden().toggleStyle(.checkbox).disabled(!maintenance.canSelect(item))
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(item.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if item.selection == .blocked {
                                            Text(item.blockedReason ?? "此项目受保护").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        } else if item.selection == .required {
                                            Text(item.requiresAuthorization == true ? "需要系统授权 · 可取消勾选" : "应用本体 · 可取消勾选").font(.caption2).foregroundStyle(NestStyle.green)
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
                    if item.requiresAuthorization == true {
                        DetailField(label: "系统授权", value: "确认后交由 Finder 移入废纸篓，需要时会出现系统授权窗口。取消授权会保留应用及相关文件。")
                    }
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
        if #available(macOS 15.4, *) {
            // 确认清单尚未执行移除；退出仍交给 AppDelegate 等待任务收尾。
            content.presentationPreventsAppTermination(false)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(NestStyle.green)
                        .frame(width: 46, height: 46)
                        .background(NestStyle.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("确认移入废纸篓").font(.system(size: 22, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(confirmation.title).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("待移入项目").font(.callout.weight(.semibold))
                        Text("\(confirmation.items.count) 项")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(NestStyle.subtle, in: Capsule())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("已知占用 \(formattedBytes(confirmation.items.compactMap(\.estimatedBytes).reduce(0, +)))")
                                .font(.callout.weight(.medium)).monospacedDigit()
                            if confirmation.items.contains(where: { $0.estimatedBytes == nil }) {
                                Text("含占用未知项目").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    confirmationItems
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("只处理以上项目，不会立即释放磁盘空间。", systemImage: "info.circle")
                        .font(.callout)
                    Text("执行前会重新核对文件和保护状态。需要恢复时，请按操作记录中的原路径手动移回。")
                        .font(.caption)
                    if confirmation.items.contains(where: { $0.requiresAuthorization == true }) {
                        Label("需要系统授权：确认后由 Finder 处理。首次使用可能需允许拾净与 Finder 协作；取消授权会保留应用。", systemImage: "lock.shield")
                            .font(.callout).foregroundStyle(NestStyle.green)
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("返回调整选择", action: cancel)
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button(confirmation.items.contains(where: { $0.requiresAuthorization == true }) ? "继续系统授权并移入废纸篓" : "将这 \(confirmation.items.count) 项移入废纸篓", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(NestStyle.subtle)
        }.frame(width: 680)
    }

    @ViewBuilder private var confirmationItems: some View {
        if confirmation.items.count == 1, let item = confirmation.items.first {
            ViewThatFits(in: .vertical) {
                confirmationItem(item)
                ScrollView { confirmationItem(item) }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // 多项按需布局，避免大清单一次撑高弹窗或渲染全部内容。
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(confirmation.items) { item in confirmationItem(item) }
                }
            }.frame(height: 240)
        }
    }

    private func confirmationItem(_ item: MaintenanceItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if item.kind == .application {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                            .resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 24)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName).font(.system(size: 17, weight: .semibold))
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(item.estimatedBytes.map(formattedBytes) ?? "占用未知")
                    .font(.callout.weight(.medium)).monospacedDigit().fixedSize()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("操作影响").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(item.impact).font(.callout)
                if item.kind == .application {
                    Text("本次包含应用本体；相关文件会在本体成功移入废纸篓后处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
    }
}
