import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    // Source builds are installed by the local signing updater. Sparkle's
    // official feed would replace them with a build that requires a license.
    private static var usesLocalUpdater: Bool {
        #if LOCAL_BUILD
            return true
        #else
            return Bundle.main.object(forInfoDictionaryKey: "VoiceInkUsesLocalUpdater") as? Bool == true
        #endif
    }

    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    private enum DefaultsKey {
        // Keep the existing persisted key strings so current user preferences migrate automatically.
        static let automaticUpdateChecks = "VoiceInkChecksForUpdatesOnLaunch"
        static let interactedUpdateVersions = "VoiceInkInteractedUpdateVersions"
        static let sparkleAutomaticChecks = "SUEnableAutomaticChecks"
    }

    private let defaults: UserDefaults
    private let localUpdater = LocalBuildUpdater()
    var canInstallLocalUpdate: () -> Bool = { false }
    @Published private(set) var localUpdateStatus: String?
    private var localCheckInProgress = false
    private var lastLocalCheckDate: Date?
    private var isUserInitiatedUpdateCheck = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    @Published var canCheckForUpdates = false
    @Published private(set) var checksForUpdatesWhenDashboardAppears = false
    @Published private(set) var availableUpdate: AvailableUpdate?

    override init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        checksForUpdatesWhenDashboardAppears = Self.initialAutomaticCheckPreference(in: defaults)
        super.init()

        if Self.usesLocalUpdater {
            canCheckForUpdates = true
            return
        }

        let updater = updaterController.updater

        // VoiceInk owns automatic discovery through Sparkle's non-presenting probe.
        // Keeping Sparkle's scheduler disabled prevents it from showing an update
        // window independently of the Dashboard button.
        updater.automaticallyChecksForUpdates = false
        updaterController.startUpdater()

        canCheckForUpdates = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool) {
        guard checksForUpdatesWhenDashboardAppears != value else { return }

        checksForUpdatesWhenDashboardAppears = value
        defaults.set(value, forKey: DefaultsKey.automaticUpdateChecks)

        if value {
            checkForUpdateInformationIfPossible()
        } else {
            availableUpdate = nil
        }
    }

    func checkForUpdatesIfDue() {
        guard checksForUpdatesWhenDashboardAppears else { return }
        if Self.usesLocalUpdater {
            if let lastLocalCheckDate, Date().timeIntervalSince(lastLocalCheckDate) < 14400 { return }
            checkLocalBuild(userInitiated: false)
            return
        }

        let updater = updaterController.updater
        guard !updater.sessionInProgress else { return }

        if let lastCheckDate = updater.lastUpdateCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheckDate)
            guard elapsed < 0 || elapsed >= updater.updateCheckInterval else { return }
        }

        checkForUpdateInformationIfPossible()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        if Self.usesLocalUpdater {
            checkLocalBuild(userInitiated: true)
            return
        }

        // Any explicit check is interaction with the currently advertised update.
        // Persist it before presenting Sparkle so dismissing or closing the native
        // window cannot make the Dashboard button reappear for the same build.
        if let availableUpdate {
            rememberInteraction(with: availableUpdate.versionIdentifier)
            self.availableUpdate = nil
        }

        if !updaterController.updater.sessionInProgress {
            isUserInitiatedUpdateCheck = true
        }
        updaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(
            versionIdentifier: item.versionString,
            displayVersion: item.displayVersionString
        )

        if isUserInitiatedUpdateCheck {
            rememberInteraction(with: update.versionIdentifier)
            availableUpdate = nil
        } else if checksForUpdatesWhenDashboardAppears && !hasInteracted(with: update.versionIdentifier) {
            availableUpdate = update
        } else {
            availableUpdate = nil
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        isUserInitiatedUpdateCheck = false
    }

    private func checkForUpdateInformationIfPossible() {
        if Self.usesLocalUpdater {
            checkLocalBuild(userInitiated: false)
            return
        }
        let updater = updaterController.updater
        guard !updater.sessionInProgress else { return }
        updater.checkForUpdateInformation()
    }

    private func hasInteracted(with versionIdentifier: String) -> Bool {
        defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions)?
            .contains(versionIdentifier) == true
    }

    private func checkLocalBuild(userInitiated: Bool) {
        guard !localCheckInProgress else { return }
        localCheckInProgress = true
        canCheckForUpdates = false
        Task {
            defer {
                localCheckInProgress = false
                canCheckForUpdates = true
                localUpdateStatus = nil
            }
            do {
                let release = try await localUpdater.latestRelease()
                lastLocalCheckDate = Date()
                guard localUpdater.needsUpdate(release) else {
                    availableUpdate = nil
                    if userInitiated {
                        localUpdater.showMessage("VoiceInk is up to date", detail: "You are using your local build of VoiceInk \(release.version).")
                    }
                    return
                }
                availableUpdate = AvailableUpdate(versionIdentifier: release.sha256, displayVersion: release.version)
                guard userInitiated else { return }
                guard canInstallLocalUpdate() else {
                    localUpdater.showMessage("Finish your recording first", detail: "Check for updates again after recording and transcription finish.")
                    return
                }
                guard localUpdater.confirmInstall(release) else { return }
                localUpdateStatus = "Downloading and verifying VoiceInk \(release.version)…"
                try await localUpdater.prepareInstall(release)
                guard canInstallLocalUpdate() else {
                    localUpdater.cancelInstall()
                    localUpdater.showMessage("Finish your recording first", detail: "The update was prepared, but VoiceInk is busy. Check for updates again when it is idle.")
                    return
                }
                localUpdateStatus = "Restarting VoiceInk…"
                NSApplication.shared.terminate(nil)
            } catch {
                localUpdater.cancelInstall()
                if userInitiated {
                    localUpdater.showMessage("VoiceInk could not update", detail: error.localizedDescription)
                }
            }
        }
    }

    private func rememberInteraction(with versionIdentifier: String) {
        var versions = defaults.stringArray(forKey: DefaultsKey.interactedUpdateVersions) ?? []
        guard !versions.contains(versionIdentifier) else { return }
        versions.append(versionIdentifier)
        defaults.set(versions, forKey: DefaultsKey.interactedUpdateVersions)
    }

    private static func initialAutomaticCheckPreference(in defaults: UserDefaults) -> Bool {
        if let preference = defaults.object(forKey: DefaultsKey.automaticUpdateChecks) as? Bool {
            return preference
        }

        // Preserve an explicit choice made through VoiceInk's previous Sparkle-backed
        // setting. With no saved choice, keep VoiceInk's existing opt-in default.
        let preference = (defaults.object(forKey: DefaultsKey.sparkleAutomaticChecks) as? Bool) ?? true

        defaults.set(preference, forKey: DefaultsKey.automaticUpdateChecks)
        return preference
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
