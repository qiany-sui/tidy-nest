import AppKit
import SwiftUI
import TidyNestCore

@main
struct TidyNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = WorkspaceModel(applicationCache: .standard)

    var body: some Scene {
        WindowGroup("拾净 · TidyNest") {
            RootView(model: model)
                .background(WindowCloseGuard(model: model))
                .tint(NestStyle.green)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    appDelegate.model = model
                    model.start()
                }
                .onDisappear { model.cancelOperation() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
        Settings {
            SettingsView(model: model)
                .tint(NestStyle.green)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    private var terminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !terminationRequested {
            let cancel: Bool
            if model.maintenance.isExecuting {
                guard let choice = maintenanceExitChoice(action: "退出") else { return .terminateCancel }
                cancel = choice
            } else { cancel = true }
            terminationRequested = true
            Task {
                await model.prepareToTerminate(cancelMaintenance: cancel)
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
