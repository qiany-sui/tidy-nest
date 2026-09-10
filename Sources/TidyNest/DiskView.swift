import SwiftUI
import TidyNestCore

struct DiskView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("磁盘").font(.system(size: 28, weight: .semibold))
                    Text("从一个文件夹开始，找到空间的去向。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 24)
                Button(action: model.chooseDirectory) { Label("选择文件夹", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canAnalyzeDisk)
            }.padding(28)

            if let directory = model.requestedDirectory {
                HStack(spacing: 12) {
                    Button(action: model.goUp) { Image(systemName: "arrow.up") }
                        .help("返回上层文件夹").disabled(!model.canAnalyzeDisk || directory.path == "/")
                        .accessibilityLabel("返回上层文件夹")
                    Image(systemName: "folder.fill").foregroundStyle(NestStyle.green)
                    Text(directory.path).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.analyze(directory: directory) } label: { Image(systemName: "arrow.clockwise") }
                        .help("重新读取").accessibilityLabel("重新读取目录").disabled(!model.canAnalyzeDisk)
                    Button { model.reveal(path: directory.path) } label: { Image(systemName: "arrow.up.forward.square") }
                        .help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示当前文件夹")
                }
                .buttonStyle(.borderless).padding(.horizontal, 28).padding(.bottom, 18)
            }
            Divider()
            if model.diskPhase == .loaded, let report = model.diskReport {
                diskResults(report)
            } else {
                QueryStatusView(phase: model.diskPhase, idleTitle: "空间，慢慢理清", idleMessage: "选择想查看的文件夹，了解其中的文件和子文件夹占用。", symbol: "internaldrive", cancel: model.cancelOperation)
            }
        }
    }

    private func diskResults(_ report: MoleDiskReport) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("总占用").font(.caption).foregroundStyle(.secondary)
                    Text(formattedBytes(report.totalSize)).font(.system(size: 30, weight: .light, design: .rounded)).foregroundStyle(NestStyle.green)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("文件数量").font(.caption).foregroundStyle(.secondary)
                    Text(report.totalFiles.formatted()).font(.system(size: 24, weight: .light, design: .rounded))
                }
                Spacer()
                Text("按占用从大到小").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider()
            if report.entries.isEmpty {
                NestEmptyState(symbol: "folder", title: "没有可显示的项目", message: "所选位置本次未返回文件或子文件夹。")
            } else {
                HSplitView {
                    List(selection: $model.selectedDiskEntryID) {
                        ForEach(model.sortedDiskEntries) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                    .font(.system(size: 22)).foregroundStyle(entry.isDirectory ? NestStyle.green : .secondary).frame(width: 30)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    GeometryReader { geometry in
                                        Capsule().fill(NestStyle.green.opacity(0.12))
                                            .overlay(alignment: .leading) {
                                                Capsule().fill(NestStyle.green.opacity(0.5))
                                                    .frame(width: geometry.size.width * proportion(entry, in: report))
                                            }
                                    }.frame(height: 4).frame(maxWidth: 150)
                                }
                                Spacer(minLength: 8)
                                Text(formattedBytes(entry.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                if entry.isDirectory {
                                    Button { model.analyze(directory: URL(fileURLWithPath: entry.path)) } label: { Image(systemName: "chevron.right") }
                                        .buttonStyle(.borderless).help("打开 \(entry.name)").accessibilityLabel("打开文件夹 \(entry.name)").disabled(!model.canAnalyzeDisk)
                                }
                            }
                            .padding(.vertical, 10).tag(entry.id)
                            .contextMenu {
                                if entry.isDirectory {
                                    Button("查看文件夹") { model.analyze(directory: URL(fileURLWithPath: entry.path)) }.disabled(!model.canAnalyzeDisk)
                                }
                                Button("在 Finder 中显示") { model.reveal(path: entry.path) }
                            }
                        }
                    }
                    .listStyle(.inset).frame(minWidth: 310, idealWidth: 440)
                    diskDetail.frame(minWidth: 260, idealWidth: 320)
                }
            }
        }
    }

    private func proportion(_ entry: MoleDiskEntry, in report: MoleDiskReport) -> Double {
        let largest = report.entries.map(\.size).max() ?? 0
        return largest == 0 ? 0 : min(1, Double(entry.size) / Double(largest))
    }

    @ViewBuilder private var diskDetail: some View {
        if let entry = model.selectedDiskEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 54, weight: .light)).foregroundStyle(NestStyle.green).padding(.top, 12)
                    Text(entry.name).font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                    Text(formattedBytes(entry.size)).font(.system(size: 28, weight: .light, design: .rounded)).foregroundStyle(NestStyle.green)
                    Divider()
                    DetailField(label: "类型", value: entry.isDirectory ? "文件夹" : "文件")
                    DetailField(label: "位置", value: entry.path)
                    if entry.isDirectory {
                        Button { model.analyze(directory: URL(fileURLWithPath: entry.path)) } label: { Label("查看文件夹", systemImage: "folder") }.disabled(!model.canAnalyzeDisk)
                    }
                    Button { model.reveal(path: entry.path) } label: { Label("在 Finder 中显示", systemImage: "arrow.up.forward.square") }
                }.controlSize(.large).padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(NestStyle.subtle.opacity(0.5))
        } else {
            NestEmptyState(symbol: "doc.text.magnifyingglass", title: "查看项目详情", message: "选择一个项目，或点击文件夹右侧箭头继续查看。")
        }
    }
}
