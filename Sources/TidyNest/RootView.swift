import SwiftUI

enum NestStyle {
    static let green = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.58, green: 0.78, blue: 0.65, alpha: 1)
        }
        return NSColor(srgbRed: 0.25, green: 0.48, blue: 0.36, alpha: 1)
    })
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let subtle = Color.primary.opacity(0.045)
}

struct RootView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(NestStyle.green)
                        .frame(width: 42, height: 42)
                        .background(NestStyle.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拾净").font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text("TIDYNEST").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 32)

                Text("工作空间").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 23).padding(.bottom, 10)
                ForEach(WorkspacePage.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol).font(.system(size: 16)).frame(width: 20)
                            Text(page.title).font(.system(size: 14, weight: .medium))
                            Spacer()
                            if model.page == page { Circle().fill(NestStyle.green).frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(model.page == page ? NestStyle.green : Color.primary.opacity(0.75))
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(model.page == page ? NestStyle.green.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 5)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        if model.isDetectingMole {
                            ProgressView().controlSize(.mini).frame(width: 10, height: 10).accessibilityHidden(true)
                        } else {
                            Circle().fill(model.installation?.isSupported == true ? NestStyle.green : Color.secondary)
                                .frame(width: 6, height: 6).frame(width: 10, height: 10)
                        }
                        Text(model.connectionLabel).font(.caption)
                        if model.isDetectingMole {
                            Button(action: model.cancelOperation) { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("取消检测").accessibilityLabel("取消检测")
                                .disabled(model.connectionPhase == .cancelling || model.isTerminating)
                        }
                    }.frame(height: 16)
                    SettingsLink { Label("设置", systemImage: "gearshape").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if model.showsConnectionNotice && model.page != .history {
                    connectionNotice
                }
                if model.maintenance.isBusy && model.page != .clean {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.maintenance.progressMessage.isEmpty ? "正在处理维护请求…" : model.maintenance.progressMessage).lineLimit(2)
                        Spacer()
                        if model.maintenance.isExecuting { Button("查看执行进度") { model.page = .clean } }
                    }.font(.callout).padding(12).background(NestStyle.green.opacity(0.07))
                }
                switch model.page {
                case .clean: MaintenanceView(model: model)
                case .applications: ApplicationsView(model: model)
                case .disk: DiskView(model: model)
                case .history: MaintenanceHistoryView(model: model)
                }
            }
            .background(NestStyle.canvas)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var connectionNotice: some View {
        Group {
            if model.showsMoleInstallation {
                MoleInstallView(model: model)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(NestStyle.green)
                    Text(connectionMessage).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    Button("重新检测", action: model.detectInstallation).disabled(model.isBusy || model.isTerminating)
                    SettingsLink { Text("详情") }
                }
            }
        }
        .font(.callout).padding(.horizontal, 24).padding(.vertical, 12)
        .background(NestStyle.green.opacity(0.07))
    }

    private var connectionMessage: String {
        if case .failed(let message) = model.connectionPhase { return message }
        if let installation = model.installation { return "当前 Mole \(installation.version) 尚未验证，暂时无法读取。" }
        if model.connectionPhase == .cancelled { return "检测已取消。重新检测后即可读取应用和磁盘。" }
        return "连接 Mole 后，查看应用与磁盘占用。"
    }
}

struct NestEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 35, weight: .light))
                .foregroundStyle(NestStyle.green)
                .frame(width: 84, height: 84)
                .background(NestStyle.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 25))
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4).textSelection(.enabled)
        }
        .frame(maxWidth: 350).padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueryStatusView: View {
    let phase: QueryPhase
    let idleTitle: String
    let idleMessage: String
    let symbol: String
    let cancel: () -> Void

    var body: some View {
        switch phase {
        case .loading:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("正在读取…").font(.headline)
                Text("读取完成后会自动显示结果").font(.callout).foregroundStyle(.secondary)
                Button("取消读取", action: cancel)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cancelling:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("正在取消读取…").font(.headline)
                Text("等待查询进程收尾后，可以开始下一项操作。").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            NestEmptyState(symbol: "exclamationmark.circle", title: "读取未完成", message: message)
        case .cancelled:
            NestEmptyState(symbol: "pause.circle", title: "已取消读取", message: "可以随时重新开始。")
        default:
            NestEmptyState(symbol: symbol, title: idleTitle, message: idleMessage)
        }
    }
}

struct DetailField: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "未知" : value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func formattedBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
