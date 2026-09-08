import Foundation
import Observation

enum LocalizationKey: String {
    case build, calibrate, rehearse, live, record, review
    case mode, stop, sources, iphoneCaptureNode, professionalVideoInput, externalTracking
    case connectLocalCamera, chromaKey, monitor, renderer, tracking, frameRate, latency, gpuFrameTime, droppedFrames, focalLength, inputColor, radialDistortion, videoProfile, stageSpace
    case ready, recording, metalFrameGraph, greenThreshold, edgeSoftness
    case language, appearance, system, light, dark, noInput, noConnectedDevices, connecting, connected, disconnected, primaryCamera
    case preparingMetalRenderer, metalPreviewActive, previewStopped, cameraAccessNotGranted, liveCameraPreviewActive
}

struct LanguageOption: Identifiable {
    let id: String
    let name: String
}

private struct LocalizationCatalog: Decodable {
    struct Language: Decodable, Identifiable {
        let id: String
        let name: String
        let translations: [String: String]
    }

    let languages: [Language]
}

/// Runtime-localizable catalog. Adding a language only requires adding one
/// language object to LocalizationCatalog.json; source code does not need a new enum case.
@MainActor @Observable
final class LocalizationStore {
    private let catalog: LocalizationCatalog

    var selectedLanguageID: String {
        didSet { UserDefaults.standard.set(selectedLanguageID, forKey: "language") }
    }

    var languages: [LanguageOption] {
        catalog.languages.map { LanguageOption(id: $0.id, name: $0.name) }
    }

    init() {
        catalog = Self.loadCatalog()
        let saved = UserDefaults.standard.string(forKey: "language") ?? ""
        selectedLanguageID = catalog.languages.contains(where: { $0.id == saved })
            ? saved
            : (Locale.current.language.languageCode?.identifier == "ja" ? "ja" : "en")
        if !catalog.languages.contains(where: { $0.id == selectedLanguageID }) {
            selectedLanguageID = catalog.languages.first?.id ?? "en"
        }
    }

    func text(_ key: LocalizationKey) -> String {
        let selected = catalog.languages.first(where: { $0.id == selectedLanguageID })
        let english = catalog.languages.first(where: { $0.id == "en" })
        return selected?.translations[key.rawValue]
            ?? english?.translations[key.rawValue]
            ?? key.rawValue
    }

    private static func loadCatalog() -> LocalizationCatalog {
        guard let url = Bundle.module.url(forResource: "LocalizationCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(LocalizationCatalog.self, from: data) else {
            return LocalizationCatalog(languages: [])
        }
        return catalog
    }
}
