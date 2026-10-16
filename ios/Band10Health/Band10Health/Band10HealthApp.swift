import Band10Sync
import SwiftUI

/// Band Sync: copies what a Xiaomi band records into Apple Health, over
/// Bluetooth, in the background, without the vendor app.
@main
struct Band10HealthApp: App {
    @StateObject private var engine: BandSyncEngine

    init() {
        let engine = BandSyncEngine(configuration: BandSyncEngine.Configuration(
            restoreIdentifier: "band10health.sync",
            keychainService: "band10health.band"
        ))
        _engine = StateObject(wrappedValue: engine)
        // Here and not in a view: iOS relaunches the app in the background for
        // Bluetooth events, without showing any window.
        engine.start()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                BandSyncView(engine: engine)
            }
        }
    }
}
