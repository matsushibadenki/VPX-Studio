import Observation
import SwiftUI

enum AppearanceOption: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor @Observable
final class AppSettings {
    var appearance: AppearanceOption {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    init() {
        appearance = AppearanceOption(
            rawValue: UserDefaults.standard.string(forKey: "appearance") ?? ""
        ) ?? .system
    }
}
