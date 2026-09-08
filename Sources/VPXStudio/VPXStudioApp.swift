import SwiftUI

@main
struct VPXStudioApp: App {
    @State private var studio = StudioModel()
    @State private var localization = LocalizationStore()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            StudioView(studio: studio, localization: localization, settings: settings)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 1440, height: 900)
    }
}
