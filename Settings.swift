import Foundation
import FluidAudio  // Phase 0 linkage check; used in earnest by the Voice pillar (Phase 2).

// MARK: - App settings store
//
// Typed, observable preferences backed by UserDefaults (same Codable idiom as
// FavoriteModel in HermesLaunch.swift), plus a helper for the app-owned data
// directory used by larger features (palette history, future meeting/voice data).

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    private init() {
        // One-time migration: the standalone brand-color picker was replaced by the
        // theme engine. Drop any saved custom brand color and fall back to the default
        // theme so there are no dangling references.
        if defaults.object(forKey: "themeId") == nil, defaults.string(forKey: "brandColorHex") != nil {
            defaults.removeObject(forKey: "brandColorHex")
        }
    }

    /// `~/Library/Application Support/HermesLaunch/` — created on first access.
    static let supportDir: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HermesLaunch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: Generic Codable persistence

    private func value<T: Codable>(_ key: String, _ fallback: T) -> T {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return decoded
    }
    private func store<T: Codable>(_ key: String, _ newValue: T) {
        if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
        objectWillChange.send()
    }

    // MARK: Global summon hotkey (Carbon key/modifier codes; see CommandPalette)

    struct Hotkey: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        /// ⌥Space by default (49 = Space). `modifiers` is filled in at registration.
        static let defaultSummon = Hotkey(keyCode: 49, modifiers: 0)
    }
    var summonHotkey: Hotkey {
        get { value("summonHotkey", .defaultSummon) }
        set { store("summonHotkey", newValue) }
    }

    // MARK: Voice preferences (Phase 2)

    struct VoicePrefs: Codable, Equatable {
        var dictationEnabled: Bool = true
        var speakReplies: Bool = false
        var ttsVoice: String = "af_heart"
    }
    var voice: VoicePrefs {
        get { value("voicePrefs", VoicePrefs()) }
        set { store("voicePrefs", newValue) }
    }

    // MARK: Theme (recolors the whole app + drives light/dark); see Theming.swift

    var themeId: String {
        get { defaults.string(forKey: "themeId") ?? HLTheme.fallback.rawValue }
        set {
            defaults.set(newValue, forKey: "themeId")
            objectWillChange.send()
        }
    }

    // MARK: Command palette history (recent command ids / queries)

    var paletteHistory: [String] {
        get { value("paletteHistory", []) }
        set { store("paletteHistory", Array(newValue.prefix(50))) }
    }
}
