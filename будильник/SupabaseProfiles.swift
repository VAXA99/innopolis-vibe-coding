import Foundation

struct SupabaseProfile: Decodable {
    let id: UUID
    let email: String?
    let paid: Bool
}

/// Работа с `public.profiles` через PostgREST (без Supabase SDK).
enum SupabaseProfiles {
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

    /// MVP-режим: отмечает профиль как оплаченный.
    static func setPaidTrue(userID: UUID, email: String) async -> SupabaseProfile? {
        guard isConfigured else { return nil }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else { return nil }
        if let updated = await updatePaidFlag(userID: userID, paid: true) {
            return updated
        }
        // Фолбэк: если строки нет, создаём/обновляем через upsert.
        return await upsertProfile(userID: userID, email: normalizedEmail, paid: true)
    }

    static func loadOrCreateProfile(userID: UUID, email: String) async -> SupabaseProfile? {
        guard isConfigured else { return nil }
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else { return nil }
        guard let existing = await loadProfile(userID: userID) else {
            return await createProfile(userID: userID, email: normalizedEmail)
        }
        return existing
    }

    private static func baseRESTURL() -> URL? {
        guard let root = URL(string: baseURLString), let host = root.host, !host.isEmpty else { return nil }
        var comp = URLComponents()
        comp.scheme = root.scheme ?? "https"
        comp.host = host
        comp.port = root.port
        comp.path = "/rest/v1/profiles"
        return comp.url
    }

    private static func loadProfile(userID: UUID) async -> SupabaseProfile? {
        guard let baseURL = baseRESTURL() else { return nil }
        guard var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id,email,paid"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            let items = try JSONDecoder().decode([SupabaseProfile].self, from: data)
            return items.first
        } catch {
            return nil
        }
    }

    private static func createProfile(userID: UUID, email: String) async -> SupabaseProfile? {
        guard let url = baseRESTURL() else { return nil }
        return await upsertProfile(userID: userID, email: email, paid: false)
    }

    private static func upsertProfile(userID: UUID, email: String, paid: Bool) async -> SupabaseProfile? {
        guard let url = baseRESTURL() else { return nil }
        struct NewProfile: Encodable {
            let id: UUID
            let email: String
            let paid: Bool
        }
        let payload = NewProfile(id: userID, email: email, paid: paid)
        guard let body = try? JSONEncoder().encode(payload) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        req.setValue("id", forHTTPHeaderField: "On-Conflict")
        req.httpBody = body
        req.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            let items = try JSONDecoder().decode([SupabaseProfile].self, from: data)
            return items.first
        } catch {
            return nil
        }
    }

    private static func updatePaidFlag(userID: UUID, paid: Bool) async -> SupabaseProfile? {
        guard let baseURL = baseRESTURL() else { return nil }
        guard var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comp.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "id,email,paid"),
        ]
        guard let url = comp.url else { return nil }

        struct PatchPayload: Encodable {
            let paid: Bool
        }
        guard let body = try? JSONEncoder().encode(PatchPayload(paid: paid)) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        req.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            let items = try JSONDecoder().decode([SupabaseProfile].self, from: data)
            return items.first
        } catch {
            return nil
        }
    }
}
