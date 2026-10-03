import AppKit
import Foundation

/// Installs only this fork's source builds through the existing local signing key.
@MainActor
final class LocalBuildUpdater {
    struct Release: Decodable {
        let version: String
        let sha256: String
    }

    private let manifestURL = URL(string: "https://github.com/meetshukla/VoiceInk/releases/download/local-build/VoiceInk-local.json")!
    private var installer: Process?

    func latestRelease() async throws -> Release {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw updateError("Your local release is not available. Try again later.")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.sha256.count == 64,
            release.sha256.allSatisfy({ $0.isHexDigit }), !release.version.isEmpty
        else { throw updateError("Your local release metadata is invalid.") }
        return release
    }

    func needsUpdate(_ release: Release) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "VoiceInkLocalBuildChecksum") as? String != release.sha256
    }

    func confirmInstall(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "VoiceInk \(release.version) is available"
        alert.informativeText = "Install your local build and restart VoiceInk. Your settings and local signing certificate will be retained."
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func prepareInstall(_ release: Release) async throws {
        guard let bundledScript = Bundle.main.url(forResource: "voiceink-local-updater", withExtension: "sh") else {
            throw updateError("The local updater is missing from this build.")
        }
        let fileManager = FileManager.default
        let stateDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInk Local Updater", isDirectory: true)
        let passwordFile = stateDirectory.appendingPathComponent("signing/keychain-password")
        guard fileManager.fileExists(atPath: passwordFile.path) else {
            throw updateError("Your local signing certificate is not configured.")
        }
        let jobDirectory = stateDirectory.appendingPathComponent("native-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = jobDirectory.appendingPathComponent("update.sh")
        try fileManager.copyItem(at: bundledScript, to: script)
        let readyFile = jobDirectory.appendingPathComponent("status")
        let logFile = jobDirectory.appendingPathComponent("update.log")
        fileManager.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: logFile)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--interactive", String(ProcessInfo.processInfo.processIdentifier), readyFile.path, release.sha256]
        var environment = ProcessInfo.processInfo.environment
        // The app always uses its own install location and the fixed fork release.
        environment.removeValue(forKey: "VOICEINK_RELEASE_BASE")
        environment.removeValue(forKey: "VOICEINK_PROCESS_NAME")
        environment.removeValue(forKey: "VOICEINK_UPDATER_STATE_DIR")
        environment["VOICEINK_APP_PATH"] = Bundle.main.bundleURL.path
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        installer = process

        for _ in 0..<2400 {
            if let status = try? String(contentsOf: readyFile, encoding: .utf8), status.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" {
                return
            }
            guard process.isRunning else {
                throw updateError("Download or signing failed. Your installed app was kept. Details: \(logFile.path)")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw updateError("The update timed out. Your installed app was kept.")
    }

    func cancelInstall() {
        if let installer, installer.isRunning { installer.terminate() }
        installer = nil
    }

    func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func updateError(_ description: String) -> NSError {
        NSError(domain: "VoiceInkLocalUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
