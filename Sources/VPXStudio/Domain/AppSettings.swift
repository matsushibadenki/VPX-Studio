import Observation
import SwiftUI
import AppKit

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

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor @Observable
final class AppSettings {
    private var systemAppearanceRevision = 0

    var effectiveColorScheme: ColorScheme {
        _ = systemAppearanceRevision
        if let scheme = appearance.colorScheme { return scheme }
        return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
    var appearance: AppearanceOption {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApplication.shared.appearance = appearance.appKitAppearance
        }
    }

    init() {
        appearance = AppearanceOption(
            rawValue: UserDefaults.standard.string(forKey: "appearance") ?? ""
        ) ?? .system
        NSApplication.shared.appearance = appearance.appKitAppearance
        // AppSettings is app-lifetime; the center owns this weak-self observer.
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemAppearanceRevision += 1 }
        }
    }
}
