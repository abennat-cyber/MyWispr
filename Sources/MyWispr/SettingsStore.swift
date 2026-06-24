import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    /// API key is kept in the Keychain and never written to UserDefaults.
    @Published var openAIAPIKey: String {
        didSet { KeychainStore.save(key: keychainAPIKeyAccount, value: openAIAPIKey) }
    }

    private let userDefaultsKey = "com.abennat.mywispr.settings"
    private let keychainAPIKeyAccount = "openAIAPIKey"

    init() {
        if
            let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        openAIAPIKey = KeychainStore.load(key: "openAIAPIKey")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}
