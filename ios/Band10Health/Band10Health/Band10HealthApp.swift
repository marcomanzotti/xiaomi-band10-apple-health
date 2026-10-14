import Band10Sync
import SwiftUI

@main
struct Band10HealthApp: App {
    private enum Tab: Hashable {
        case importer
        case band
        case sync
    }

    /// `--band-sync` starts the background sync engine. This test app never
    /// writes to Health and, unless `--band-ack` is given, leaves every file on
    /// the band: the real sync lives in FitTracker.
    private static let syncArgument = "--band-sync"
    private static let acknowledgeArgument = "--band-ack"

    @StateObject private var engine: BandSyncEngine
    @State private var selection: Tab

    init() {
        var configuration = BandSyncEngine.Configuration(
            restoreIdentifier: "com.band10health.app.sync",
            keychainService: "com.band10health.band"
        )
        configuration.writesToHealth = false
        configuration.acknowledgesFiles = CommandLine.arguments.contains(Self.acknowledgeArgument)
        _engine = StateObject(wrappedValue: BandSyncEngine(configuration: configuration))
        let startsSync = CommandLine.arguments.contains(Self.syncArgument)
        _selection = State(initialValue: startsSync ? .sync : BandProbeView.shouldOpenAtLaunch ? .band : .importer)
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                ContentView()
                    .tabItem { Label("Importa", systemImage: "square.and.arrow.down") }
                    .tag(Tab.importer)
                BandProbeView()
                    .tabItem { Label("Band", systemImage: "applewatch.radiowaves.left.and.right") }
                    .tag(Tab.band)
                NavigationStack {
                    BandSyncView(engine: engine)
                }
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.sync)
            }
            .task {
                if CommandLine.arguments.contains(Self.syncArgument) {
                    engine.start()
                }
            }
        }
    }
}
