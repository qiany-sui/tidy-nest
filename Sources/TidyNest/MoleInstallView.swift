import SwiftUI

struct MoleInstallView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.installPhase == .loading || model.installPhase == .cancelling {
                ProgressView().controlSize(.small).padding(.top, 3)
            } else {
                Image(systemName: model.installPhase == .loaded ? "checkmark.circle" : "arrow.down.circle")
                    .foregroundStyle(NestStyle.green).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.medium))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if model.installPhase != .loaded && model.installPhase != .cancelling {
                    HStack(spacing: 10) {
                        if model.installPhase == .loading {
                            Button("取消安装", action: model.cancelOperation).disabled(model.isTerminating)
                        } else {
                            if model.moleNotInstalled {
                                Button(model.installPhase == .idle ? "安装 Mole 1.53.0" : "重新安装", action: model.installMole)
                                    .buttonStyle(.borderedProminent).tint(NestStyle.green)
                                    .disabled(!model.canInstallMole)
                            }
                            Button("重新检测", action: model.detectInstallation).disabled(model.isBusy || model.isTerminating)
                        }
                    }.padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch model.installPhase {
        case .loading: model.installProgress?.message ?? "正在准备安装 Mole…"
        case .cancelling: "正在取消安装，等待清理…"
        case .cancelled: "安装已取消"
        case .failed: "安装未完成"
        case .loaded: "Mole 已安装并通过重新检测"
        default: "未找到 Mole"
        }
    }

    private var message: String? {
        switch model.installPhase {
        case .loading: "安装完成后会自动重新检测。"
        case .cancelling: "任务收尾完成后，可以重新开始。"
        case .cancelled: "安装任务已结束，可以重新安装或检测。"
        case .failed(let message): message
        case .loaded: nil
        default: "将 Mole 1.53.0 安装到当前用户目录，完成后即可读取应用和磁盘。"
        }
    }
}
