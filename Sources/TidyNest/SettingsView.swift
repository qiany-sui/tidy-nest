import SwiftUI
import TidyNestCore

struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    @State private var protectionToRemove: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "leaf.fill").font(.system(size: 30)).foregroundStyle(NestStyle.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("拾净 · TidyNest").font(.title2.weight(.semibold))
                        Text("看清应用，理清空间。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Text("Mole 连接").font(.headline)
                    Spacer()
                    if !model.showsMoleInstallation || model.installPhase == .loaded {
                        if model.connectionPhase == .loading {
                            ProgressView().controlSize(.small)
                            Button("取消", action: model.cancelOperation)
                        } else {
                            Button("重新检测", action: model.detectInstallation).disabled(model.isBusy || model.isTerminating)
                        }
                    }
                }
                if model.showsMoleInstallation { MoleInstallView(model: model) }
                if let installation = model.installation {
                    DetailField(label: "可执行文件", value: installation.executableURL.path)
                    HStack(alignment: .top) {
                        DetailField(label: "版本", value: installation.version)
                        DetailField(label: "支持状态", value: installation.isSupported ? "已验证，可读取" : "尚未验证，读取已停用")
                    }
                } else if !model.showsMoleInstallation {
                    Text(model.connectionLabel).font(.callout).foregroundStyle(.secondary)
                }
                if case .failed(let message) = model.connectionPhase, !model.showsMoleInstallation {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("应用列表与磁盘查询支持 Mole \(MoleInstallation.supportedVersions.joined(separator: "、"))。清理计划与逐项移入废纸篓由随包维护引擎处理。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Label("长期保护", systemImage: "shield").font(.headline)
                    Spacer()
                    Button("刷新") { model.maintenance.reloadProtections() }.disabled(!model.maintenance.canStart)
                }
                Text("这里列出拾净保存的保护项。可在计划详情中添加保护；任何保护配置变化都会使当前计划失效。")
                    .font(.caption).foregroundStyle(.secondary)
                protectionContent
                if let notice = model.maintenance.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(30)
        }.frame(width: 560, height: 660)
        .task { if model.maintenance.protectionsPhase == .idle { model.maintenance.reloadProtections() } }
        .alert("取消长期保护？", isPresented: Binding(get: { protectionToRemove != nil }, set: { if !$0 { protectionToRemove = nil } })) {
            Button("保留保护", role: .cancel) { protectionToRemove = nil }
            Button("取消保护", role: .destructive) {
                if let path = protectionToRemove { model.maintenance.changeProtection(path: path, protected: false) }
                protectionToRemove = nil
            }
        } message: {
            Text("\(protectionToRemove ?? "")\n取消后需要重新扫描。是否成为候选，仍取决于其他保护规则。")
        }
    }

    @ViewBuilder private var protectionContent: some View {
        switch model.maintenance.protectionsPhase {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("正在读取保护设置…").font(.callout) }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .loaded:
            if model.maintenance.protectedPaths.isEmpty {
                Text("没有额外添加的保护项。内置保护规则仍然生效。").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    ForEach(model.maintenance.protectedPaths, id: \.self) { path in
                        HStack(alignment: .top) {
                            Text(path).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button("取消保护…") { protectionToRemove = path }.disabled(!model.maintenance.canStart)
                        }
                    }
                }
            }
        case .cancelled:
            Text("保护设置读取已取消。").font(.callout).foregroundStyle(.secondary)
        default:
            Text("点击刷新，读取本机保护设置。").font(.callout).foregroundStyle(.secondary)
        }
    }
}
