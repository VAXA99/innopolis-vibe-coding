#if canImport(MediaPlayer) && os(iOS)
import AVFoundation
import Foundation
import MediaPlayer
#if canImport(MusicKit)
import MusicKit
#endif

/// Подготовка Apple Music / медиатеки для будильника.
/// При необходимости включите в Xcode **Signing & Capabilities → MusicKit** (и профиль в Developer), иначе достаточно `NSAppleMusicUsageDescription` + MusicKit.framework.
enum AlarmAppleMusicPlayback {
    private static var didRegisterMPPlaybackNotifications = false

    /// Apple: без этого `applicationMusicPlayer` может не слать состояние и нестабильно стартовать.
    @MainActor
    static func ensureMPMusicPlayerNotificationsRegistered() {
        guard !didRegisterMPPlaybackNotifications else { return }
        didRegisterMPPlaybackNotifications = true
        MPMusicPlayerController.applicationMusicPlayer.beginGeneratingPlaybackNotifications()
    }

    /// Запросить доступ к медиатеке и MusicKit заранее (меньше отказов в момент срабатывания будильника).
    static func requestAuthorizationsIfNeeded() async {
        if MPMediaLibrary.authorizationStatus() != .authorized {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
            }
        }
        #if canImport(MusicKit)
        _ = await MusicAuthorization.request()
        #endif
        await MainActor.run {
            try? AudioManager.configureSessionForAppleMusicAlarm()
        }
    }
}
#endif

#if canImport(MusicKit) && os(iOS)
import MusicKit

extension AlarmAppleMusicPlayback {
    /// Подбор `Song` для будильника: каталог по ID → медиатека по ID → поиск в каталоге → нечёткое совпадение в медиатеке.
    static func resolveSongForAlarm(selection: AlarmMelodySelection, storeID: String) async -> Song? {
        let trimmed = storeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return await fuzzyLibrarySong(selection: selection) }
        let itemID = MusicItemID(rawValue: trimmed)

        if let s = await fetchCatalogSong(id: itemID) { return s }
        if let s = await fetchLibrarySong(id: itemID) { return s }

        if let s = await catalogSearchSong(selection: selection) { return s }
        return await fuzzyLibrarySong(selection: selection)
    }

    private static func fetchCatalogSong(id: MusicItemID) async -> Song? {
        do {
            let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: id)
            let resp = try await req.response()
            return resp.items.first
        } catch {
            return nil
        }
    }

    private static func fetchLibrarySong(id: MusicItemID) async -> Song? {
        do {
            let libReq = MusicLibraryRequest<Song>()
            let libResp = try await libReq.response()
            return libResp.items.first(where: { $0.id == id })
        } catch {
            return nil
        }
    }

    private static func catalogSearchSong(selection: AlarmMelodySelection) async -> Song? {
        let terms = [
            "\(selection.artist) \(selection.title)".trimmingCharacters(in: .whitespacesAndNewlines),
            selection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }
        for term in terms {
            guard term.count >= 2 else { continue }
            do {
                var req = MusicCatalogSearchRequest(term: term, types: [Song.self])
                req.limit = 15
                let resp = try await req.response()
                let wantTitle = selection.title.lowercased()
                let wantArtist = selection.artist.lowercased()
                if let best = resp.songs.first(where: { song in
                    let t = song.title.lowercased()
                    let a = song.artistName.lowercased()
                    let titleOK = t == wantTitle || t.contains(wantTitle) || wantTitle.contains(t)
                    let artistOK = wantArtist.isEmpty || a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a)
                    return titleOK && artistOK
                }) {
                    return best
                }
                if let first = resp.songs.first { return first }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func fuzzyLibrarySong(selection: AlarmMelodySelection) async -> Song? {
        let wantTitle = selection.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard wantTitle.count >= 2 else { return nil }
        let wantArtist = selection.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let libReq = MusicLibraryRequest<Song>()
            let libResp = try await libReq.response()
            return libResp.items.first { song in
                let t = song.title.lowercased()
                let a = song.artistName.lowercased()
                let titleOK = t == wantTitle || t.contains(wantTitle) || wantTitle.contains(t)
                let artistOK = wantArtist.isEmpty || a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a)
                return titleOK && artistOK
            }
        } catch {
            return nil
        }
    }
}
#endif
