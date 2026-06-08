import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var writer = HealthKitWriter()

    @State private var showImporter = false
    @State private var loadedExport: SleepExport?
    @State private var loadedFilename: String?
    @State private var status: String = "Pronto."
    @State private var isWorking = false
    @State private var didError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Autorizzazione") {
                    Button {
                        Task { await authorize() }
                    } label: {
                        Label("Richiedi accesso ad Apple Health", systemImage: "heart.text.square")
                    }
                    .disabled(isWorking)
                }

                Section("2 · Carica dati sonno (JSON)") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Scegli file JSON…", systemImage: "doc.badge.plus")
                    }
                    .disabled(isWorking)

                    if let export = loadedExport {
                        LabeledContent("File", value: loadedFilename ?? "—")
                        LabeledContent("Sorgente", value: export.source)
                        LabeledContent("Notti", value: "\(export.nights.count)")
                        let stages = export.nights.reduce(0) { $0 + $1.stages.count }
                        LabeledContent("Segmenti fase", value: "\(stages)")
                    }
                }

                Section("3 · Scrivi in Apple Health") {
                    Button {
                        Task { await writeToHealth() }
                    } label: {
                        Label("Importa in Salute", systemImage: "square.and.arrow.down")
                    }
                    .disabled(loadedExport == nil || isWorking)
                }

                Section("Stato") {
                    if isWorking { ProgressView() }
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(didError ? .red : .secondary)
                }
            }
            .navigationTitle("Band 10 → Salute")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    // MARK: Actions

    private func authorize() async {
        isWorking = true; defer { isWorking = false }
        do {
            try await writer.requestAuthorization()
            set("Autorizzazione richiesta. Conferma le voci in Salute.", error: false)
        } catch {
            set("Errore autorizzazione: \(error.localizedDescription)", error: true)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let export = try JSONDecoder().decode(SleepExport.self, from: data)
            loadedExport = export
            loadedFilename = url.lastPathComponent
            set("Caricato \(export.nights.count) notti da \(url.lastPathComponent).", error: false)
        } catch {
            loadedExport = nil
            set("Errore lettura JSON: \(error.localizedDescription)", error: true)
        }
    }

    private func writeToHealth() async {
        guard let export = loadedExport else { return }
        isWorking = true; defer { isWorking = false }
        do {
            let n = try await writer.save(export: export)
            set("✅ Scritti \(n) campioni in Apple Health.", error: false)
        } catch {
            set("Errore scrittura: \(error.localizedDescription)", error: true)
        }
    }

    private func set(_ text: String, error: Bool) {
        status = text
        didError = error
    }
}

#Preview {
    ContentView()
}
