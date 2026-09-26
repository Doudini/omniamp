import Foundation

/// 10-band graphic EQ (Winamp's classic band layout), ±12 dB per band plus preamp.
enum Equalizer {
    static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    static let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
    static let range: Float = 12

    struct Settings: Codable, Equatable {
        var enabled = false
        var preamp: Float = 0
        var bands: [Float] = Array(repeating: 0, count: 10)
    }

    struct Preset {
        let name: String
        let preamp: Float
        let bands: [Float]
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", preamp: 0, bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Rock", preamp: -2, bands: [5, 4, 2, -1, -2, 1, 3, 5, 5, 5]),
        Preset(name: "Pop", preamp: -1, bands: [-1, 2, 4, 5, 3, 0, -1, -1, -1, -1]),
        Preset(name: "Jazz", preamp: -1, bands: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        Preset(name: "Classical", preamp: 0, bands: [0, 0, 0, 0, 0, 0, -4, -4, -4, -6]),
        Preset(name: "Dance", preamp: -3, bands: [7, 5, 2, 0, 0, -2, -3, -3, 0, 0]),
        Preset(name: "Full Bass", preamp: -4, bands: [8, 8, 6, 3, 1, -2, -4, -5, -6, -6]),
        Preset(name: "Full Treble", preamp: -4, bands: [-6, -6, -6, -3, 1, 5, 8, 9, 9, 9]),
        Preset(name: "Bass & Treble", preamp: -3, bands: [6, 5, 1, -3, -2, 1, 5, 7, 7, 7]),
        Preset(name: "Vocal", preamp: -1, bands: [-3, -2, 0, 3, 4, 4, 2, 0, -1, -2]),
        Preset(name: "Loudness", preamp: -3, bands: [6, 4, 0, 0, -2, 0, -1, 3, 5, 4]),
        Preset(name: "Laptop Speakers", preamp: -2, bands: [4, 6, 3, -1, -1, 1, 3, 6, 7, 7]),
    ]

    private static let key = "equalizer"

    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        if s.bands.count != 10 { s.bands = Array((s.bands + Array(repeating: 0, count: 10)).prefix(10)) }
        return s
    }

    static func save(_ s: Settings) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
}
