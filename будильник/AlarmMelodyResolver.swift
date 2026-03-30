#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer

/// Находит трек в медиатеке: по ID, по Store ID каталога, по названию — иначе `MPMediaQuery` по одному persistentID часто даёт nil (облако, смена библиотеки), и будильник падал во встроенный WAV.
enum AlarmMelodyResolver {
    static func resolve(selection: AlarmMelodySelection) -> MPMediaItem? {
        if let item = queryPersistentID(selection.persistentID) { return item }
        if let sid = selection.playbackStoreID, !sid.isEmpty {
            if let item = queryPlaybackStoreID(sid) { return item }
            let digits = sid.filter(\.isNumber)
            if digits != sid, !digits.isEmpty, let item = queryPlaybackStoreID(digits) { return item }
        }
        if let item = matchByTitleAndArtist(selection) { return item }
        return matchByTitleOnly(selection)
    }

    private static func queryPersistentID(_ id: UInt64) -> MPMediaItem? {
        guard id != 0 else { return nil }
        let q = MPMediaQuery.songs()
        let pred = MPMediaPropertyPredicate(
            value: NSNumber(value: id),
            forProperty: MPMediaItemPropertyPersistentID,
            comparisonType: .equalTo
        )
        q.addFilterPredicate(pred)
        return q.items?.first
    }

    private static func queryPlaybackStoreID(_ id: String) -> MPMediaItem? {
        let q = MPMediaQuery.songs()
        let pred = MPMediaPropertyPredicate(
            value: id,
            forProperty: MPMediaItemPropertyPlaybackStoreID,
            comparisonType: .equalTo
        )
        q.addFilterPredicate(pred)
        return q.items?.first
    }

    private static func matchByTitleAndArtist(_ sel: AlarmMelodySelection) -> MPMediaItem? {
        let title = sel.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = sel.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let q = MPMediaQuery.songs()
        let pred = MPMediaPropertyPredicate(
            value: sel.title,
            forProperty: MPMediaItemPropertyTitle,
            comparisonType: .contains
        )
        q.addFilterPredicate(pred)
        guard let items = q.items else { return nil }
        for item in items {
            let t = (item.title ?? "").lowercased()
            let a = (item.artist ?? "").lowercased()
            let titleMatch = t == title || t.contains(title)
            let artistMatch = artist.isEmpty || a == artist || a.contains(artist)
            if titleMatch && artistMatch { return item }
        }
        return nil
    }

    private static func matchByTitleOnly(_ sel: AlarmMelodySelection) -> MPMediaItem? {
        let title = sel.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        let q = MPMediaQuery.songs()
        let pred = MPMediaPropertyPredicate(
            value: sel.title,
            forProperty: MPMediaItemPropertyTitle,
            comparisonType: .contains
        )
        q.addFilterPredicate(pred)
        guard let items = q.items else { return nil }
        for item in items {
            let t = (item.title ?? "").lowercased()
            if t == title || t.contains(title) || title.contains(t) { return item }
        }
        return nil
    }
}
#endif
