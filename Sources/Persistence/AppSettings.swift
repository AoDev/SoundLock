import Foundation
import ServiceManagement

/// Launch-at-login toggle backed by `SMAppService`.
final class AppSettings: ObservableObject {
    @Published var promptOnNewOutputDevice = UserDefaults.standard.bool(forKey: Constants.DefaultsKey.promptOnNewOutputDevice) {
        didSet { UserDefaults.standard.set(promptOnNewOutputDevice, forKey: Constants.DefaultsKey.promptOnNewOutputDevice) }
    }

    var launchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[SoundLock] SMAppService error (%@): %@",
                      newValue ? "register" : "unregister", error.localizedDescription)
            }
        }
    }
}
