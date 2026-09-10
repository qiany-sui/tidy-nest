import AppKit
import SwiftUI
import TidyNestCore

struct ApplicationsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用").font(.system(size: 28, weight: .semibold))
                    Text("了解 Mac 上的应用，从一份清晰的列表开始。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                Button(action: model.loadApplications) {
                    Label(model.hasApplicationSnapshot ? "刷新列表" : "读取应用", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canQuery)
            }
            .padding(28)
            Divider()

            if model.hasApplicationSnapshot { refreshStatus }

            if !model.applications.isEmpty {
                HSplitView {
                    applicationList.frame(minWidth: 310, idealWidth: 410)
                    // 固定分栏宿主，避免空态与应用详情切换时重新分配宽度。
                    GeometryReader { geometry in
                        applicationDetail.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(minWidth: 285, idealWidth: 360)
                }
            } else if model.hasApplicationSnapshot {
                NestEmptyState(symbol: "square.grid.2x2", title: model.applicationsPhase == .loaded ? "没有找到应用" : "上次列表为空", message: model.applicationsPhase == .loaded ? "Mole 本次未返回应用。你可以稍后刷新列表。" : "列表更新后会在这里显示应用。")
            } else {
                QueryStatusView(phase: model.applicationsPhase, idleTitle: "你的应用，一目了然", idleMessage: "点击「读取应用」，查看应用的来源、位置和大小。", symbol: "square.grid.2x2", cancel: model.cancelOperation)
            }
        }
    }

    private var refreshStatus: some View {
        HStack(spacing: 10) {
            if model.applicationsPhase == .loading || model.applicationsPhase == .cancelling || model.applicationRefreshPhase == .loading || model.applicationRefreshPhase == .cancelling {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(refreshMessage).textSelection(.enabled)
                if let updatedAt = model.applicationsUpdatedAt {
                    Text("完整列表更新于 \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                if let notice = model.applicationCacheNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.applicationRefreshPhase == .loading {
                Button("取消刷新", action: model.cancelOperation)
            } else if model.applicationsPhase == .loading {
                Button("取消更新", action: model.cancelOperation)
            }
        }
        .font(.caption).padding(.horizontal, 28).padding(.vertical, 10)
        .background(NestStyle.green.opacity(0.07))
    }

    private var refreshMessage: String {
        if let application = model.applicationRefreshTarget {
            switch model.applicationRefreshPhase {
            case .loading: return "正在刷新「\(application.name)」，其他应用保持不变。"
            case .cancelling: return "正在取消「\(application.name)」的刷新，等待查询收尾…"
            case .loaded: return "「\(application.name)」已刷新，其他应用保持不变。"
            case .cancelled: return "「\(application.name)」的刷新已取消，保留原信息。"
            case .failed(let message): return "「\(application.name)」刷新失败，保留原信息。\(message)"
            case .idle: break
            }
        }
        return switch model.applicationsPhase {
        case .idle: "可刷新完整列表，也可选中应用单独刷新。"
        case .loading: "正在更新，仍可浏览上次列表。"
        case .cancelling: "正在取消更新，等待查询收尾…"
        case .cancelled: "更新已取消，显示上次列表。"
        case .failed(let message): "更新失败，显示上次列表。\(message)"
        case .loaded: "列表已更新。"
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用名称", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
            .padding(10).background(NestStyle.subtle, in: RoundedRectangle(cornerRadius: 8)).padding(16)
            HStack {
                Text("\(model.filteredApplications.count) 个应用")
                Spacer()
                Text("按名称排序")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 19).padding(.bottom, 9)

            if model.filteredApplications.isEmpty {
                NestEmptyState(symbol: "magnifyingglass", title: "没有匹配的应用", message: "试试其他名称。")
            } else {
                List(selection: $model.selectedApplicationID) {
                    ForEach(model.filteredApplications) { application in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                                .resizable().interpolation(.high).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(application.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(application.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            Text(application.displaySize.isEmpty ? "未知" : application.displaySize).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8).tag(application.id)
                    }
                }.listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var applicationDetail: some View {
        if let application = model.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path)).resizable().interpolation(.high).frame(width: 72, height: 72)
                        Text(application.name).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                        Text(application.displaySize.isEmpty ? "占用未知" : application.displaySize)
                            .font(.system(size: 28, weight: .light, design: .rounded)).foregroundStyle(NestStyle.green)
                    }.padding(.top, 12)
                    Divider()
                    DetailField(label: "来源", value: application.source)
                    DetailField(label: "Bundle ID", value: application.bundleIdentifier)
                    DetailField(label: "位置", value: application.path)
                    VStack(alignment: .leading, spacing: 10) {
                        Button { model.refreshApplication(application) } label: {
                            Label("刷新此应用", systemImage: "arrow.clockwise")
                        }.controlSize(.large).disabled(!model.canRefreshApplication(application))
                        Button { model.reveal(path: application.path) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                            .controlSize(.large)
                    }
                    Divider()
                    Button { model.openUninstallPlan(application) } label: {
                        Label("检查移除计划", systemImage: "checklist")
                    }.controlSize(.large).disabled(!model.canPlanUninstall(application))
                    Text("可直接检查移除计划，无需先刷新。检查时会重新核验应用与相关文件，再由你确认移入废纸篓。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(NestStyle.subtle.opacity(0.5))
        } else {
            NestEmptyState(symbol: "app.dashed", title: "查看应用详情", message: "从左侧选择一个应用。")
        }
    }
}
