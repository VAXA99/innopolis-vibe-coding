import Foundation

/// Прямое подключение приложения к Supabase через PostgREST (без SPM).
/// В Info.plist задайте `SUPABASE_URL` и `SUPABASE_ANON_KEY` (Settings → API → anon public).
/// В SQL выполните миграцию `002_app_registrations_anon_insert.sql`.
enum SupabaseDirectRegistration {
    private static var baseURLString: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var anonKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isConfigured: Bool {
        !baseURLString.isEmpty && !anonKey.isEmpty
    }

    /// После успешной регистрации на вашем backend — дублирует строку в таблицу `app_registrations`.
    static func syncUserAfterSignup(email: String, fullName: String) async {
        guard isConfigured else { return }
        guard let root = URL(string: baseURLString), let host = root.host, !host.isEmpty else { return }

        var comp = URLComponents()
        comp.scheme = root.scheme ?? "https"
        comp.host = host
        comp.port = root.port
        comp.path = "/rest/v1/app_registrations"

        guard let url = comp.url else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        struct Row: Encodable {
            let email: String
            let full_name: String?
            let registered_at: String
        }

        let row = Row(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            full_name: fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            registered_at: iso.string(from: Date())
        )

        guard let body = try? JSONEncoder().encode(row) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        req.timeoutInterval = 30

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) {
                return
            }
        } catch {
            return
        }
    }
}
