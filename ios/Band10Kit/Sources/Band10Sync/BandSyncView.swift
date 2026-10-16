// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings screen for the band: state of the connection, the key, Health
/// permission and the recent diary. The sync itself needs no button.
/// English, with the translations in Resources/<language>.lproj.
public struct BandSyncView: View {
    @ObservedObject private var engine: BandSyncEngine
    @State private var keyText = ""
    @State private var keyError = false

    public init(engine: BandSyncEngine) {
        self.engine = engine
    }

    public var body: some View {
        Form {
            statusSection
            healthSections
            keySection
            if !engine.recentLog.isEmpty {
                Section {
                    ForEach(Array(engine.recentLog.reversed().enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.system(.caption2, design: .monospaced))
                    }
                } header: {
                    Text("Diary", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("Xiaomi band", bundle: .module))
    }

    private var statusSection: some View {
        Section {
            row("Band", phaseText)
            if let battery = engine.batteryLevel {
                row("Battery", "\(battery)%")
            }
            row("Last sync", engine.lastSync?.formatted(date: .abbreviated, time: .shortened)
                ?? String(localized: "never", bundle: .module))
            if let result = engine.lastResult {
                row("Result", result)
            }
            if engine.pendingFileCount > 0 {
                row("Files waiting for Health", "\(engine.pendingFileCount)")
            }
            Button { engine.syncNow() } label: { Text("Sync now", bundle: .module) }
                .disabled(engine.phase != .connected)
        } header: {
            Text("Status", bundle: .module)
        }
    }

    @ViewBuilder private var healthSections: some View {
        if case .answered(let allowed, let total) = engine.healthAccess, allowed < total {
            Section {
                if allowed == 0 {
                    Text("Health does not let this app write the band's data.", bundle: .module)
                } else {
                    Text("Health lets this app write only \(allowed) of \(total) data types.", bundle: .module)
                }
                Button { Task { await engine.requestHealthAccess() } } label: {
                    Text("Ask Health again", bundle: .module)
                }
                Text("If no request appears: Settings → Privacy & Security → Health → this app, under \"Allow to write\". Data already downloaded is written by itself.", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Health permissions", bundle: .module)
            }
        }
        if engine.healthAccess == .notRequested {
            Section {
                Button { Task { await engine.requestHealthAccess() } } label: {
                    Text("Allow writing to Health", bundle: .module)
                }
            } footer: {
                Text("Steps, energy, distance, heart rate, SpO₂ and sleep from the band. Tap \"Turn On All\" in the sheet that opens.", bundle: .module)
            }
        }
    }

    private var keySection: some View {
        Section {
            SecureField(String(localized: "32 hexadecimal digits", bundle: .module), text: $keyText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            #if canImport(UIKit)
            Button { keyText = UIPasteboard.general.string ?? "" } label: {
                Text("Paste", bundle: .module)
            }
            #endif
            Button { saveKey() } label: { Text("Save key", bundle: .module) }
                .disabled(keyText.isEmpty)
            if keyError {
                Text("Not a valid key: it must be 32 hexadecimal digits.", bundle: .module).foregroundStyle(.red)
            }
        } header: {
            Text("Band key", bundle: .module)
        } footer: {
            Text("Needed once after every pairing of the band. It stays on this iPhone only.", bundle: .module)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(title, bundle: .module)
        }
    }

    private var phaseText: String {
        switch engine.phase {
        case .stopped: String(localized: "stopped", bundle: .module)
        case .needsKey: String(localized: "key missing", bundle: .module)
        case .bluetoothUnavailable: String(localized: "Bluetooth off or not allowed", bundle: .module)
        case .waitingForBand: String(localized: "waiting for the band to be near", bundle: .module)
        case .connecting: String(localized: "connecting…", bundle: .module)
        case .authenticating: String(localized: "authenticating…", bundle: .module)
        case .connected: String(localized: "connected", bundle: .module)
        case .syncing: String(localized: "syncing…", bundle: .module)
        case .keyRejected: String(localized: "key rejected: the band needs its new key", bundle: .module)
        }
    }

    private func saveKey() {
        do {
            try engine.setAuthKey(hex: keyText)
            keyText = ""
            keyError = false
        } catch {
            keyError = true
        }
    }
}
