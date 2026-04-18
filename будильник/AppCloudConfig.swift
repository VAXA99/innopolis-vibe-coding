import Foundation

/// Облачный backend (`huawei-sync-server` на Render). Регистрация пишет пользователей в файл на сервере.
enum AppCloudConfig {
    /// Единственное место, где задаётся адрес для пользователей **без ввода в приложении**.
    static let embeddedServiceRootURL: String = "https://innopolis-vibe-coding.onrender.com"

    static func serviceRootFromInfoPlist() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "REGISTRATION_API_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Адрес для регистрации и синка: сначала вшитая строка, иначе `REGISTRATION_API_BASE_URL` в Info.plist.
    static var resolvedServiceRootURL: String {
        let embedded = embeddedServiceRootURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !embedded.isEmpty { return embedded }
        return serviceRootFromInfoPlist()
    }
}
