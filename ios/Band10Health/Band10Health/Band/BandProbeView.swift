import SwiftUI

/// Shows the read-only Bluetooth survey of the band and lets the log be shared.
struct BandProbeView: View {
    /// Launch argument that opens this tab and starts the survey without a tap,
    /// so it can be driven from Xcode or `devicectl`.
    static let autoStartArgument = "--band-probe"
    static var shouldAutoStart: Bool { CommandLine.arguments.contains(autoStartArgument) }
    /// True when any launch argument asks for this tab.
    static var shouldOpenAtLaunch: Bool { shouldAutoStart || BandBindCheck.shouldAutoStart || BandPairing.shouldAutoStart || BandAuthCheck.shouldAutoStart }

    @StateObject private var probe = BandProbe()
    @StateObject private var bindCheck = BandBindCheck()
    @StateObject private var pairing = BandPairing()
    @StateObject private var authCheck = BandAuthCheck()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        probe.start()
                    } label: {
                        Label("Avvia sonda Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(probe.isRunning)

                    if probe.isRunning {
                        ProgressView("Lettura in corso…")
                    }
                } footer: {
                    Text("Sola lettura: elenca i servizi della band senza inviarle nulla.")
                }

                Section {
                    Button {
                        bindCheck.start()
                    } label: {
                        Label("Verifica stato associazione", systemImage: "link.badge.plus")
                    }
                    .disabled(bindCheck.isRunning)

                    ForEach(Array(bindCheck.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Apre una sessione con la band e le chiede se è già associata. Può far riconnettere Mi Fitness.")
                }

                Section {
                    Button {
                        pairing.start()
                    } label: {
                        Label("Associa la band (dopo il reset)", systemImage: "lock.open")
                    }
                    .disabled(pairing.isRunning)

                    if pairing.needsConfirmationOnBand {
                        Label("Conferma sullo schermo della band", systemImage: "hand.tap")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(pairing.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Da usare solo con la band appena ripristinata: crea la chiave tra telefono e band, senza Mi Fitness.")
                }

                Section {
                    Button {
                        authCheck.start()
                    } label: {
                        Label("Verifica la chiave", systemImage: "key")
                    }
                    .disabled(authCheck.isRunning)

                    ForEach(Array(authCheck.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Si autentica con la chiave salvata e chiede modello, firmware e batteria. Mi Fitness deve essere chiusa.")
                }

                Section("Log") {
                    if probe.lines.isEmpty {
                        Text("Nessun dato.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(probe.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Band")
            .toolbar {
                ShareLink(item: probe.lines.joined(separator: "\n"))
                    .disabled(probe.lines.isEmpty)
            }
            .task {
                if Self.shouldAutoStart {
                    probe.start()
                }
                if BandBindCheck.shouldAutoStart {
                    bindCheck.start()
                }
                if BandPairing.shouldAutoStart {
                    pairing.start()
                }
                if BandAuthCheck.shouldAutoStart {
                    authCheck.start()
                }
            }
        }
    }
}
