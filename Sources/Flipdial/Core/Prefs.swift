import Foundation

enum Prefs {
    private static let defaults = UserDefaults.standard

    /// Lossy quality for JPG/HEIC/WebP output, 0.1...1.0.
    static var imageQuality: Double {
        get { defaults.object(forKey: "imageQuality") as? Double ?? 0.85 }
        set { defaults.set(newValue, forKey: "imageQuality") }
    }

    /// Resolution PDF pages are rendered at when exporting images.
    static var pdfDPI: Double {
        get { defaults.object(forKey: "pdfDPI") as? Double ?? 300 }
        set { defaults.set(newValue, forKey: "pdfDPI") }
    }

    static var keepMetadata: Bool {
        get { defaults.object(forKey: "keepMetadata") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepMetadata") }
    }

    static var revealWhenDone: Bool {
        get { defaults.bool(forKey: "revealWhenDone") }
        set { defaults.set(newValue, forKey: "revealWhenDone") }
    }

    static var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    /// When set, every output goes here instead of next to the original.
    static var customOutputFolder: URL? {
        get { defaults.string(forKey: "customOutputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "customOutputFolder") }
    }

    static var conversionCount: Int {
        get { defaults.integer(forKey: "conversionCount") }
        set { defaults.set(newValue, forKey: "conversionCount") }
    }
}
