import SwiftUI
import Combine

struct AlarmMelodySelection: Equatable {
    let persistentID: UInt64
    /// Каталог Apple Music (iTunes Store ID) — если persistentID перестал находиться, ищем/играем по нему.
    let playbackStoreID: String?
    let title: String
    let artist: String

    var subtitle: String {
        artist.isEmpty ? title : "\(title) - \(artist)"
    }
}

enum AlarmMelodyStorage {
    private static let idKey = "alarmMelody.persistentID"
    private static let storeIdKey = "alarmMelody.playbackStoreID"
    private static let titleKey = "alarmMelody.title"
    private static let artistKey = "alarmMelody.artist"

    static func save(_ selection: AlarmMelodySelection) {
        // NSNumber — иначе UInt64 из UserDefaults читается как nil и Apple Music не находится.
        UserDefaults.standard.set(NSNumber(value: selection.persistentID), forKey: idKey)
        if let sid = selection.playbackStoreID, !sid.isEmpty {
            UserDefaults.standard.set(sid, forKey: storeIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storeIdKey)
        }
        UserDefaults.standard.set(selection.title, forKey: titleKey)
        UserDefaults.standard.set(selection.artist, forKey: artistKey)
    }

    static func load() -> AlarmMelodySelection? {
        let id: UInt64
        if let n = UserDefaults.standard.object(forKey: idKey) as? NSNumber {
            id = n.uint64Value
        } else if let u = UserDefaults.standard.object(forKey: idKey) as? UInt64 {
            id = u
        } else {
            return nil
        }
        guard id != 0 else { return nil }
        let storeID = UserDefaults.standard.string(forKey: storeIdKey)
        let title = UserDefaults.standard.string(forKey: titleKey) ?? "Selected song"
        let artist = UserDefaults.standard.string(forKey: artistKey) ?? ""
        return AlarmMelodySelection(persistentID: id, playbackStoreID: storeID, title: title, artist: artist)
    }
}

#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer

@MainActor
final class AppleMusicAlarmManager: ObservableObject {
    @Published private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
    @Published private(set) var currentSelection: AlarmMelodySelection?

    private let player = MPMusicPlayerController.applicationMusicPlayer

    init() {
        authorizationStatus = MPMediaLibrary.authorizationStatus()
        currentSelection = AlarmMelodyStorage.load()
    }

    func requestAccess() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
        authorizationStatus = status
        return status == .authorized
    }

    func setSelection(_ item: MPMediaItem) {
        let selection = AlarmMelodySelection(
            persistentID: item.persistentID,
            playbackStoreID: item.playbackStoreID,
            title: item.title ?? "Selected song",
            artist: item.artist ?? ""
        )
        currentSelection = selection
        AlarmMelodyStorage.save(selection)
    }

    func clearSelection() {
        currentSelection = nil
        UserDefaults.standard.removeObject(forKey: "alarmMelody.persistentID")
        UserDefaults.standard.removeObject(forKey: "alarmMelody.playbackStoreID")
        UserDefaults.standard.removeObject(forKey: "alarmMelody.title")
        UserDefaults.standard.removeObject(forKey: "alarmMelody.artist")
    }

    func previewCurrentSong() {
        guard let item = resolveCurrentItem() else { return }
        AlarmAppleMusicPlayback.ensureMPMusicPlayerNotificationsRegistered()
        AlarmApplicationMusicPlayer.configureSessionForAlarm()
        player.stop()
        player.setQueue(with: MPMediaItemCollection(items: [item]))
        player.currentPlaybackTime = 0
        player.play()
    }

    func stopPreview() {
        player.stop()
    }

    private func resolveCurrentItem() -> MPMediaItem? {
        guard let selection = currentSelection else { return nil }
        return AlarmMelodyResolver.resolve(selection: selection)
    }
}

struct MediaSongPickerSheet: UIViewControllerRepresentable {
    let onPick: (MPMediaItem) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.delegate = context.coordinator
        picker.showsCloudItems = true
        picker.allowsPickingMultipleItems = false
        picker.prompt = "Choose alarm melody"
        return picker
    }

    func updateUIViewController(_: MPMediaPickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItem) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (MPMediaItem) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            mediaPicker.dismiss(animated: true)
            onCancel()
        }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            mediaPicker.dismiss(animated: true)
            if let first = collection.items.first {
                onPick(first)
            } else {
                onCancel()
            }
        }
    }
}
#else
@MainActor
final class AppleMusicAlarmManager: ObservableObject {
    @Published private(set) var currentSelection: AlarmMelodySelection?

    func requestAccess() async -> Bool { false }
    func setSelection(_: Any) {}
    func clearSelection() { currentSelection = nil }
    func previewCurrentSong() {}
    func stopPreview() {}
}

struct MediaSongPickerSheet: View {
    let onPick: (Any) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Apple Music picker is available on iPhone only.")
            Button("Close") { onCancel() }
        }
        .padding()
    }
}
#endif
