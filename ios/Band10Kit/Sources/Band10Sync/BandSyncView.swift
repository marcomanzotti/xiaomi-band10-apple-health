// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import SwiftUI

/// Settings screen for the band: state of the connection, the key, Health
/// permission and the recent diary. The sync itself needs no button.
public struct BandSyncView: View {
    @ObservedObject private var engine: BandSyncEngine
    @State private var keyText = ""
    @State private var keyError: String?

    public init(engine: BandSyncEngine) {
        self.engine = engine
    }

    public var body: some View {
        Form {
            Section("Stato") {
                LabeledContent("Band", value: phaseText)
                if let battery = engine.batteryLevel {
                    LabeledContent("Batteria", value: "\(battery)%")
                }
                LabeledContent("Ultima sincronizzazione", value: lastSyncText)
                if let result = engine.lastResult {
                    LabeledContent("Esito", value: result)
                }
                if engine.pendingFileCount > 0 {
                    LabeledContent("File da scrivere in Salute", value: "\(engine.pendingFileCount)")
                }
                Button("Sincronizza ora") { engine.syncNow() }
                    .disabled(engine.phase != .connected)
            }

            if case .answered(let allowed, let total) = engine.healthAccess, allowed < total {
                Section {
                    Text(allowed == 0
                         ? "Salute non permette a quest'app di scrivere i dati della band."
                         : "Salute permette di scrivere solo \(allowed) dati su \(total).")
                    Button("Chiedi di nuovo a Salute") {
                        Task { await engine.requestHealthAccess() }
                    }
                    Text("Se non compare nessuna richiesta: Impostazioni → Privacy e sicurezza → Salute → quest'app, voci in \"Consenti di scrivere\". I dati già scaricati vengono scritti da soli.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Permessi di Salute")
                }
            }

            if engine.healthAccess == .notRequested {
                Section {
                    Button("Consenti di scrivere in Salute") {
                        Task { await engine.requestHealthAccess() }
                    }
                } footer: {
                    Text("Passi, energia, distanza, battito, SpO₂ e sonno della band.")
                }
            }

            Section {
                SecureField("32 cifre esadecimali", text: $keyText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Salva chiave") { saveKey() }
                    .disabled(keyText.isEmpty)
                if let keyError {
                    Text(keyError).foregroundStyle(.red)
                }
            } header: {
                Text("Chiave della band")
            } footer: {
                Text("Serve una volta dopo ogni associazione della band. Resta solo su questo iPhone.")
            }

            if !engine.recentLog.isEmpty {
                Section("Diario") {
                    ForEach(Array(engine.recentLog.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("Xiaomi Band 10")
    }

    private var phaseText: String {
        switch engine.phase {
        case .stopped: "ferma"
        case .needsKey: "manca la chiave"
        case .bluetoothUnavailable: "Bluetooth spento o non consentito"
        case .waitingForBand: "in attesa che sia vicina"
        case .connecting: "connessione…"
        case .authenticating: "autenticazione…"
        case .connected: "collegata"
        case .syncing: "sincronizzazione…"
        case .keyRejected: "chiave rifiutata: serve quella nuova"
        }
    }

    private var lastSyncText: String {
        engine.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "mai"
    }

    private func saveKey() {
        do {
            try engine.setAuthKey(hex: keyText)
            keyText = ""
            keyError = nil
        } catch {
            keyError = "Chiave non valida: servono 32 cifre esadecimali."
        }
    }
}
