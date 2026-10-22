import AppKit
import CryptoKit
import Foundation
import Security

/// Keeps the app current from the GitHub releases: checks for a newer version, downloads the DMG,
/// verifies its checksum and code signature, swaps the app in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "palermostest25/multicam-studio"
    static let automaticKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 6 * 3600

    struct Release {
        let version: String
        let notes: String
        let dmg: URL
        let checksum: URL?
        let page: URL
    }

    @Published private(set) var working = false
    /// Shows progress in the window's status bar.
    var report: (String) -> Void = { _ in }
    /// True while an export runs; updates wait for it.
    var isBusy: () -> Bool = { false }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Called at launch: a quiet check at most every few hours, if automatic checks are on.
    func checkInBackground() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true else { return }
        guard Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) > Self.interval else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let release = try await latestRelease()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if let release, Self.isNewer(release.version, than: currentVersion) {
                offer(release)
            } else if userInitiated {
                inform("You’re up to date.", "Multicam Studio \(currentVersion) is the latest version.")
            }
        } catch {
            if userInitiated { inform("Couldn’t check for updates.", error.localizedDescription) }
        }
    }

    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let dmg = asset("-macOS.dmg") else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(Self.repository)/releases")!
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       notes: json["body"] as? String ?? "", dmg: dmg, checksum: asset("-macOS.dmg.sha256"), page: page)
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Multicam Studio \(release.version) is available"
        var notes = release.notes.replacingOccurrences(of: "**", with: "")
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        alert.informativeText = "You have \(currentVersion).\n\n\(notes)"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if isBusy() {
                inform("Finish the export first.", "Then choose Multicam Studio ▸ Check for Updates… to install \(release.version).")
                return
            }
            Task { await install(release) }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    private func install(_ release: Release) async {
        working = true
        defer { working = false }
        let target = Bundle.main.bundleURL
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MulticamUpdate-\(UUID().uuidString)", isDirectory: true)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw MulticamUpdateError("Move Multicam Studio to your Applications folder first, then try again.")
            }
            report("Downloading Multicam Studio \(release.version)…")
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmg)
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            if let checksum = release.checksum {
                let (data, _) = try await URLSession.shared.data(from: checksum)
                let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                guard try Self.sha256(of: dmg) == expected else { throw MulticamUpdateError("The download was damaged. Try again later.") }
            }
            report("Installing Multicam Studio \(release.version)…")
            try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let fresh = mount.appendingPathComponent("Multicam Studio.app")
            try Self.checkSignature(of: fresh, matches: target)
            // Stage beside the current app (same volume), then swap once this process has quit.
            let staged = target.deletingLastPathComponent().appendingPathComponent(".Multicam Studio \(release.version).app")
            try? FileManager.default.removeItem(at: staged)
            try Self.run("/usr/bin/ditto", [fresh.path, staged.path])
            let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
            rm -rf "$2.old"
            if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
            xattr -dr com.apple.quarantine "$2" 2>/dev/null
            open "$2"
            """
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script, "multicam-update", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
            try helper.run()
            report("Relaunching…")
            NSApp.terminate(nil)
        } catch {
            report("Update failed.")
            inform("Couldn’t install the update.", error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: work)
    }

    private func inform(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: helpers

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MulticamUpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output)") }
        return output
    }

    /// The new app must carry a valid signature from the same developer (team) as this one.
    nonisolated static func checkSignature(of candidate: URL, matches current: URL) throws {
        func info(_ url: URL) throws -> (team: String?, identifier: String?) {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
                throw MulticamUpdateError("The update isn’t a valid app.")
            }
            guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
                throw MulticamUpdateError("The update’s signature isn’t valid, so it wasn’t installed.")
            }
            var signing: CFDictionary?
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
            let dict = signing as? [String: Any] ?? [:]
            return (dict[kSecCodeInfoTeamIdentifier as String] as? String, dict[kSecCodeInfoIdentifier as String] as? String)
        }
        let new = try info(candidate), old = try info(current)
        guard new.identifier == old.identifier, new.team == old.team else {
            throw MulticamUpdateError("The update is signed by a different developer, so it wasn’t installed.")
        }
    }
}

struct MulticamUpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
