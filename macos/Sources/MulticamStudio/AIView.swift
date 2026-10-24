import MulticamCore
import Security
import SwiftUI

/// AI mode is completely optional: with it off, the app is exactly as before.
enum AIMode {
    static let key = "aiMode"
}

/// The OpenRouter key lives in the login Keychain, never in the project file.
enum OpenRouterKey {
    private static let service = "Multicam Studio OpenRouter"
    static func load() -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct AISettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage("aiProvider") private var provider = AIGuide.Provider.claude.rawValue
    @AppStorage("aiModel") private var model = ""
    @State private var key = ""
    @State private var hasKey = !OpenRouterKey.load().isEmpty

    var choice: AIGuide.Provider { AIGuide.Provider(rawValue: provider) ?? .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("AI guidance", "Say what you want in plain words. The AI turns it into the same settings you would choose by hand, so the cuts keep their style. Nothing changes until you apply, and Undo puts everything back.")
            Picker("AI", selection: $provider) {
                ForEach(AIGuide.Provider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: provider) { state.aiResult = nil }
            TextField(choice == .openrouter ? AIGuide.defaultOpenRouterModel : "Model (optional, default)", text: $model)
                .help("Leave empty for the default model")
                .onChange(of: model) { if state.aiResult?.failed == true { state.aiResult = nil } }
            switch choice {
            case .openrouter:
                HStack {
                    SecureField(hasKey ? "Key saved in your Keychain" : "OpenRouter API key", text: $key)
                    Button(key.isEmpty && hasKey ? "Remove" : "Save") {
                        OpenRouterKey.save(key)
                        key = ""
                        hasKey = !OpenRouterKey.load().isEmpty
                    }
                    .disabled(key.isEmpty && !hasKey)
                }
                Text("The key is kept in your Keychain, not in the project.").font(.caption).foregroundStyle(.secondary)
            case .claude:
                Text("Uses the claude command-line tool on this Mac, which has its own sign-in (separate from the Claude app). To sign it in, run “claude auth login” in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            case .codex:
                Text("Uses the Codex app signed in on this Mac. If it asks you to sign in, run “codex login” in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("What do you want?")
            TextEditor(text: $state.aiPrompt)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if state.aiPrompt.isEmpty {
                Text("e.g. More of camera C in the drops, no social clips from the first two minutes, black and white for the breakdown clips.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if state.currentAnalysis == nil {
                Text("Sync & Analyse first so the AI knows where the drops and breakdowns are.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    state.askAI(provider: choice, model: model.trimmingCharacters(in: .whitespaces), key: OpenRouterKey.load())
                } label: {
                    if state.aiRunning { ProgressView().controlSize(.small); Text("Asking the AI…") } else { Text("Apply guidance") }
                }
                .glassButton(prominent: true)
                .disabled(state.aiRunning || state.busy || state.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if state.aiUndo != nil {
                    Button("Undo") { state.undoAI() }.glassButton()
                }
            }
            if let result = state.aiResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.summary).foregroundStyle(result.failed ? .red : .primary)
                    ForEach(result.changes, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        }
    }
}
