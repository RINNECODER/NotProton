import Foundation
import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController

    var available: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    init() {
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        #if !DEBUG
        if available { controller.checkForUpdates(nil) }
        #endif
    }
}
