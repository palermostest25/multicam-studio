import AVKit
import MulticamCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showInspector = true
    @State private var showLog = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if state.hasSources {
                    PreviewPane()
                    Divider()
                    EditTimeline()
                        .frame(minHeight: 190, idealHeight: 230)
                } else {
                    WelcomeView()
                }
                StatusBar(showLog: $showLog)
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { state.handleDrop($0) }
            return true
        }
        .alert("Multicam Studio", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .sheet(isPresented: $showLog) { LogView().environmentObject(state) }
        .navigationTitle(state.projectURL?.deletingPathExtension().lastPathComponent ?? "Multicam Studio")
        .navigationSubtitle(state.isDirty && state.projectURL != nil ? "Edited" : "")
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.analyse()
            } label: {
                Label(state.allAnalysed ? "Synced" : "Sync & Analyse", systemImage: state.allAnalysed ? "checkmark.circle" : "waveform.badge.magnifyingglass")
            }
            .help("Sync every camera to the audio, find the beat and drops, and score each camera's picture")
            .disabled(state.busy || !state.hasSources)

            Button { state.shuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
                .help("Try a different edit with the same settings (new seed)")
                .disabled(state.currentAnalysis == nil)

            if state.busy {
                Button(role: .cancel) { state.cancel() } label: { Label("Cancel", systemImage: "stop.circle") }
            } else {
                Button { state.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Render the full edit and/or short clips to the output folder")
                    .keyboardShortcut("e")
                    .disabled(!state.hasSources)
            }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls = [URL]()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        MainActor.assumeIsolated { completion(sorted) }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Turn a DJ set into content").font(.largeTitle.weight(.semibold))
            Text("Drop in the set's audio and every camera angle. Multicam Studio syncs them, cuts between angles on the beat, and exports a full edit for YouTube plus vertical clips for Reels, Shorts and TikTok.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button { state.addAudio(state.pickFiles(audio: true)) } label: {
                    Label(state.parts.isEmpty ? "Add Audio" : "Audio Added ✓", systemImage: "waveform")
                        .frame(minWidth: 140)
                }
                Button {
                    let urls = state.pickFiles(audio: false)
                    for url in urls { state.addCamera(with: [url]) }
                } label: {
                    Label("Add Cameras", systemImage: "video").frame(minWidth: 140)
                }
            }
            .controlSize(.large)
            .glassButton(prominent: true)
            .glassGroup(spacing: 12)
            Text("Or drag files anywhere into this window. Each video becomes its own camera; add more parts to a camera from the sidebar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack(spacing: 18) {
                Button("Open a saved project…") { state.open() }.buttonStyle(.link)
                Button("Make clips from a finished video…") { state.newFromFinishedVideo() }.buttonStyle(.link)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showLog: Bool
    @AppStorage(Appearance.key) private var glass = true
    var body: some View {
        if glass {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassCapsule()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar)
        }
    }

    var content: some View {
        HStack(spacing: 10) {
            if state.busy {
                if let progress = state.progress {
                    ProgressView(value: progress).frame(width: 160)
                    Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(state.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let error = state.planError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
            }
            if !state.lastOutputs.isEmpty && !state.busy {
                Button("Show in Finder") { state.revealOutputs() }.buttonStyle(.link)
            }
            Button { showLog = true } label: {
                Image(systemName: state.log.contains(where: \.isWarning) ? "exclamationmark.bubble" : "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Activity log")
        }
        .font(.callout)
    }
}

struct LogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.log.map(\.text).joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(state.log) { line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.isWarning ? .orange : .primary)
                        .textSelection(.enabled)
                        .id(line.id)
                }
                .onAppear { if let last = state.log.last { proxy.scrollTo(last.id) } }
            }
        }
        .frame(width: 720, height: 460)
    }
}
