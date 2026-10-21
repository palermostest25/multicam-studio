import AppKit
import MulticamCore
import SwiftUI

@main
struct MulticamStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Multicam Studio", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.state = state }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { state.newProject() }.keyboardShortcut("n")
                Button("Open Project…") { state.open() }.keyboardShortcut("o")
                Button("Make Clips from a Finished Video…") { state.newFromFinishedVideo() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Add Audio…") { state.addAudio(state.pickFiles(audio: true)) }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Add Camera…") {
                    let urls = state.pickFiles(audio: false)
                    if !urls.isEmpty { state.addCamera(with: urls) }
                }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { state.save() }.keyboardShortcut("s")
                Button("Save Project As…") { state.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Edit Video") {
                Button("Sync & Analyse") { state.analyse() }.keyboardShortcut("r").disabled(state.busy || !state.hasSources)
                Button("Shuffle Cuts") { state.shuffle() }.keyboardShortcut("j")
                Divider()
                Button("Export") { state.export() }.keyboardShortcut("e").disabled(state.busy)
                Button("Cancel") { state.cancel() }.keyboardShortcut(".").disabled(!state.busy)
                Divider()
                Button("Show Exports in Finder") { state.revealOutputs() }
            }
        }
        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in self.state?.open(url) }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.phase == .rendering else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An export is still running."
        alert.informativeText = "Quit and stop it? Videos that already finished are kept."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertSecondButtonReturn { state.cancel(); return .terminateNow }
        return .terminateCancel
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Picker("Camera picture analysis", selection: $state.project.vision) {
                Text("On (recommended)").tag("auto")
                Text("Off").tag("off")
            }
            Toggle("Correct camera clock drift", isOn: $state.project.drift)
            Toggle("Find breakdowns and drops automatically", isOn: $state.project.autoSections)
            LabeledContent("Analysis cache") {
                Button("Clear") { try? FileManager.default.removeItem(at: Cache.directory) }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
