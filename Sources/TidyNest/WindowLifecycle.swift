import AppKit
import SwiftUI

@MainActor
func maintenanceExitChoice(action: String) -> Bool? {
    let alert = NSAlert()
    alert.messageText = "正在移入废纸篓，要何时\(action)？"
    alert.informativeText = "可以等待本次操作完成，或取消剩余项目后等待收尾。已经完成的移动会保留，并记录最终结果。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "等待完成后\(action)")
    alert.addButton(withTitle: "取消剩余并\(action)")
    alert.addButton(withTitle: "继续使用")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return false
    case .alertSecondButtonReturn: return true
    default: return nil
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let model: WorkspaceModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private let model: WorkspaceModel
        private weak var previousDelegate: (any NSWindowDelegate)?
        private weak var window: NSWindow?
        private var closing = false
        private var mayClose = false

        init(model: WorkspaceModel) { self.model = model }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if mayClose { return previousDelegate?.windowShouldClose?(sender) ?? true }
            guard !closing else { return false }
            guard model.isBusy else { return previousDelegate?.windowShouldClose?(sender) ?? true }
            let cancel: Bool
            if model.maintenance.isExecuting {
                guard let choice = maintenanceExitChoice(action: "关闭窗口") else { return false }
                cancel = choice
            } else { cancel = true }
            closing = true
            Task {
                await model.prepareToCloseWindow(cancelMaintenance: cancel)
                mayClose = true
                sender.performClose(nil)
            }
            return false
        }

        func windowWillClose(_ notification: Notification) { previousDelegate?.windowWillClose?(notification) }
        func windowDidResize(_ notification: Notification) { previousDelegate?.windowDidResize?(notification) }
        func windowDidBecomeKey(_ notification: Notification) { previousDelegate?.windowDidBecomeKey?(notification) }
        func windowDidResignKey(_ notification: Notification) { previousDelegate?.windowDidResignKey?(notification) }
    }
}

final class WindowAttachmentView: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attach?(window) }
    }
}
