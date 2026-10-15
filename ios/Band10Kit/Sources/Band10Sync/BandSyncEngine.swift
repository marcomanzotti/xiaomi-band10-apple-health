// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Band10Kit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the phone connected to the band and moves its recorded data into
/// Health, with no action from the user: authenticates on every connection,
/// sets the band's clock, downloads new files (on connection and then at most
/// every `minimumSyncInterval`), saves them to disk, acknowledges them and
/// writes them to Health as soon as Health can be written.
@MainActor
public final class BandSyncEngine: ObservableObject {
    public struct Configuration: Sendable {
        /// Lets the system relaunch the app for Bluetooth events; unique per app.
        public var restoreIdentifier: String
        public var keychainService: String
        /// False only for a test app that must not write to Health.
        public var writesToHealth = true
        /// False leaves every file on the band, for example while another app
        /// still reads it.
        public var acknowledgesFiles = true
        public var minimumSyncInterval: TimeInterval = 15 * 60
        public var phoneName = "iPhone"

        public init(restoreIdentifier: String, keychainService: String) {
            self.restoreIdentifier = restoreIdentifier
            self.keychainService = keychainService
        }
    }

    public enum Phase: Equatable, Sendable {
        case stopped
        case needsKey
        case bluetoothUnavailable(String)
        case waitingForBand
        case connecting
        case authenticating
        case connected
        case syncing
        /// The band refused the key: it was paired again and has a new one.
        case keyRejected
    }

    @Published public private(set) var phase = Phase.stopped
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var lastResult: String?
    @Published public private(set) var batteryLevel: Int?
    @Published public private(set) var pendingFileCount = 0
    @Published public private(set) var healthAccess = HealthAccess.unavailable
    @Published public private(set) var recentLog: [String] = []

    /// Called after values were written to Health, so the host app can read them
    /// back at once instead of waiting for its next scheduled import.
    public var onHealthDataWritten: (@MainActor () -> Void)?

    private enum Timing {
        static let replyTimeout: Duration = .seconds(8)
        static let authenticationTimeout: Duration = .seconds(20)
        /// Pause after several sessions in a row ended badly, not to wear out the band.
        static let backoff: TimeInterval = 10 * 60
        static let failuresBeforeBackoff = 3
        static let keepProcessedFiles: TimeInterval = 14 * 24 * 3600
    }

    private static let lastSyncKey = "lastSync"
    /// How many data types Health allowed at the last import.
    private static let allowedTypesKey = "allowedHealthTypes"
    private static let writerVersionKey = "healthWriterVersion"
    private static let writerVersion = 2
    /// `--band-set-authkey <32 hex digits>` stores a key at launch, so that a Mac
    /// can hand over a new key without typing it on the phone.
    private static let setKeyArgument = "--band-set-authkey"
    /// Feature bits Gadgetbridge sends; the band's activity sync works with them.
    private static let appCapability: UInt32 = 224

    private let configuration: Configuration
    private let keychain: BandKeychain
    private let store: ActivityFileStore?
    private let writer = HealthStoreWriter()
    private let log: BandSyncLog
    private let defaults: UserDefaults
    private var link: BandLink?
    private var authenticator: Authenticator?
    private var cipher: SessionCipher?
    private var sync: ActivitySync?
    private var replyTimer: Task<Void, Never>?
    private var periodicSync: Task<Void, Never>?
    private var isImporting = false
    private var importRequestedAgain = false
    private var consecutiveFailures = 0
    /// A proof that does not match can be a reply left over from an earlier
    /// session; the key is declared wrong only when a fresh session fails too.
    private var hasRetriedMismatch = false
    /// Commands that decrypt to nothing readable, in a row. Several mean another
    /// app (Mi Fitness) authenticated on the shared link and the band now uses
    /// its session keys.
    private var unreadableCommands = 0
    private static let unreadableCommandsBeforeReauthentication = 3
    private var pausedUntil: Date?
    private var lastSyncAttempt: Date?
    private var notificationObservers: [NSObjectProtocol] = []
    #if canImport(UIKit)
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    public init(configuration: Configuration) {
        self.configuration = configuration
        keychain = BandKeychain(service: configuration.keychainService)
        store = try? ActivityFileStore.standard()
        log = BandSyncLog(folder: store?.root)
        defaults = UserDefaults(suiteName: configuration.restoreIdentifier) ?? .standard
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
        healthAccess = writer.access
    }

    // MARK: - Public controls

    /// Call at every launch, including when the system relaunches the app in the
    /// background for a Bluetooth event. Does nothing until a key is stored.
    public func start() {
        guard link == nil else { return }
        storeKeyFromLaunchArgument()
        // Before the first unlock after a restart the Keychain cannot be read:
        // start anyway, so a Bluetooth relaunch is not missed.
        guard keyState != .absent else {
            phase = .needsKey
            return
        }
        note("avvio")
        let link = BandLink(restoreIdentifier: configuration.restoreIdentifier, defaults: defaults) { [weak self] event in
            self?.handle(event)
        }
        self.link = link
        phase = .connecting
        link.start()
        observeApplication()
        schedulePeriodicSync()
        Task { await importPending() }
    }

    public func stop() {
        link?.stop()
        link = nil
        endSession()
        periodicSync?.cancel()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
        phase = hasKey ? .stopped : .needsKey
        note("fermato")
    }

    /// Downloads at once, without waiting for the interval.
    public func syncNow() {
        guard cipher != nil else {
            note("sincronizzazione richiesta ma la band non è collegata")
            return
        }
        startSync()
    }

    public func setAuthKey(hex: String) throws {
        try keychain.saveAuthKey(hex: hex)
        note("chiave salvata")
        stop()
        start()
    }

    public func removeAuthKey() throws {
        stop()
        try keychain.removeAuthKey()
        phase = .needsKey
    }

    public func requestHealthAccess() async {
        do {
            try await writer.requestAccess()
        } catch {
            note("permesso Salute non ottenuto: \(error.localizedDescription)")
        }
        healthAccess = writer.access
        await importPending()
    }

    private enum KeyState {
        case present
        case absent
        /// The phone has not been unlocked since it started.
        case unreadable
    }

    private var keyState: KeyState {
        do {
            return try keychain.loadAuthKey() == nil ? .absent : .present
        } catch {
            return .unreadable
        }
    }

    private var hasKey: Bool {
        keyState != .absent
    }

    private func storeKeyFromLaunchArgument() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: Self.setKeyArgument), arguments.indices.contains(index + 1) else {
            return
        }
        do {
            try keychain.saveAuthKey(hex: arguments[index + 1])
            note("chiave ricevuta all'avvio e salvata")
        } catch {
            note("chiave ricevuta all'avvio non valida")
        }
    }

    // MARK: - Link events

    private func handle(_ event: BandLinkEvent) {
        switch event {
        case .log(let message):
            note(message)
        case .unavailable(let reason):
            phase = .bluetoothUnavailable(reason)
            note(reason)
        case .waitingForBand:
            phase = .waitingForBand
        case .sessionOpen:
            beginAuthentication()
        case .payload(let payload):
            handle(payload)
        case .disconnected(let reason):
            note(reason)
            if phase == .authenticating || phase == .syncing {
                registerFailure()
            }
            endSession()
            if phase != .keyRejected {
                phase = .waitingForBand
            }
        }
    }

    private func handle(_ payload: XiaomiDataPayload) {
        let body: Data
        switch payload.opcode {
        case .plaintext:
            body = payload.body
        case .encrypted:
            guard let cipher, let plain = try? cipher.decrypt(payload.body) else {
                // Left over from a session of an earlier run: ignore.
                return
            }
            body = plain
        }
        switch (payload.channel, payload.opcode) {
        case (.command, .plaintext):
            handleHandshake(body)
        case (.command, .encrypted):
            handleCommand(body)
        case (.activity, _):
            perform(sync?.handle(piece: body) ?? [])
        case (.data, _):
            break
        }
    }

    // MARK: - Authentication

    private func beginAuthentication() {
        // A repeated session confirmation must not restart a handshake or a live session.
        guard authenticator == nil, cipher == nil else { return }
        if let pausedUntil, pausedUntil > Date() {
            note("in pausa fino alle \(pausedUntil.formatted(date: .omitted, time: .shortened)) dopo vari errori")
            armTimer(.seconds(pausedUntil.timeIntervalSinceNow)) { [weak self] in
                self?.link?.reopenSession()
            }
            return
        }
        let key: Data
        switch Result(catching: { try keychain.loadAuthKey() }) {
        case .success(let stored?):
            key = stored
        case .success(nil):
            phase = .needsKey
            return
        case .failure:
            // Retried when the phone is unlocked (see `observeApplication`).
            note("Portachiavi non ancora leggibile: attendo lo sblocco")
            return
        }
        do {
            authenticator = try Authenticator(authKey: key, companion: companion)
        } catch {
            note("chiave non utilizzabile")
            phase = .keyRejected
            return
        }
        phase = .authenticating
        beginBackgroundTime()
        armTimer(Timing.authenticationTimeout) { [weak self] in
            self?.note("la band non completa l'autenticazione")
            self?.registerFailure()
            self?.link?.reopenSession()
        }
        perform(authenticator?.start() ?? [])
    }

    private var companion: Authenticator.Companion {
        #if canImport(UIKit)
        let version = Float(UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "") ?? 0
        #else
        let version = Float(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #endif
        return Authenticator.Companion(
            deviceType: .iOS,
            systemVersion: version,
            phoneName: configuration.phoneName,
            region: (Locale.current.region?.identifier ?? "IT").uppercased(),
            appCapability: Self.appCapability
        )
    }

    private func handleHandshake(_ body: Data) {
        guard let reply = try? AuthReply.parse(body) else {
            note("risposta di autenticazione illeggibile")
            return
        }
        switch reply {
        case .deviceVerify: note("band: numero casuale e prova ricevuti")
        case .accepted: note("band: prova del telefono accettata")
        case .rejected(let subtype, let status): note("band: rifiuto (sottotipo \(subtype), stato \(status))")
        }
        perform(authenticator?.handle(reply) ?? [])
    }

    private func perform(_ actions: [Authenticator.Action]) {
        for action in actions {
            switch action {
            case .send(let command):
                link?.send(XiaomiDataPayload(channel: .command, opcode: .plaintext, body: command))
            case .authenticated(let cipher):
                didAuthenticate(cipher)
            case .failed(let failure):
                replyTimer?.cancel()
                note("autenticazione fallita: \(failure)")
                if failure == .keyMismatch, !hasRetriedMismatch {
                    hasRetriedMismatch = true
                    authenticator = nil
                    note("riprovo una volta con una sessione nuova")
                    link?.reopenSession()
                } else if failure == .keyMismatch || failure == .invalidAuthKey {
                    phase = .keyRejected
                    link?.stop()
                    link = nil
                } else {
                    authenticator = nil
                    registerFailure()
                    link?.reopenSession()
                }
                endBackgroundTime()
            }
        }
    }

    private func didAuthenticate(_ cipher: SessionCipher) {
        replyTimer?.cancel()
        self.cipher = cipher
        authenticator = nil
        hasRetriedMismatch = false
        phase = .connected
        note("autenticata")
        sendEncrypted(SystemCommand.setClock(to: Date(), in: .current, usesTwelveHourFormat: Self.usesTwelveHourClock))
        sendEncrypted(SystemCommand.batteryRequest)
        if isSyncDue {
            startSync()
        } else {
            endBackgroundTime()
        }
    }

    /// Follows the phone's own setting, as the band shows the time like the phone.
    private static var usesTwelveHourClock: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    private func sendEncrypted(_ command: Data) {
        guard let cipher, let body = try? cipher.encrypt(command) else { return }
        link?.send(XiaomiDataPayload(channel: .command, opcode: .encrypted, body: body))
    }

    // MARK: - Commands from the band

    private func handleCommand(_ body: Data) {
        guard let header = try? CommandHeader.parse(body) else {
            unreadableCommands += 1
            guard unreadableCommands >= Self.unreadableCommandsBeforeReauthentication else { return }
            note("la band usa chiavi di un'altra sessione (un'altra app?): mi riautentico")
            unreadableCommands = 0
            registerFailure()
            endSession()
            phase = .connecting
            link?.reopenSession()
            return
        }
        unreadableCommands = 0
        switch header.type {
        case HealthCommand.commandType:
            if let reply = try? HealthReply.parse(body) {
                perform(sync?.handle(reply) ?? [])
            }
        case SystemCommand.commandType:
            if case .battery(let level)? = try? SystemReply.parse(body) {
                batteryLevel = level
            }
        default:
            // Requests the band makes on its own (weather, alarms...): not served.
            break
        }
        // The band wakes the app now and then: use it to sync in the background.
        if sync == nil, isSyncDue {
            startSync()
        }
    }

    // MARK: - Activity download

    private var isSyncDue: Bool {
        guard let lastSyncAttempt else { return true }
        return Date().timeIntervalSince(lastSyncAttempt) >= configuration.minimumSyncInterval
    }

    private func startSync() {
        guard cipher != nil, sync == nil else { return }
        lastSyncAttempt = Date()
        beginBackgroundTime()
        sync = ActivitySync(acknowledgesFiles: configuration.acknowledgesFiles)
        phase = .syncing
        perform(sync?.start() ?? [])
    }

    private func perform(_ actions: [ActivitySync.Action]) {
        for action in actions {
            switch action {
            case .send(let command):
                sendEncrypted(command)
            case .store(let file):
                guard save(file) else {
                    // Without a copy on disk the band must keep the file.
                    finishSync(result: "interrotta: impossibile salvare i file")
                    return
                }
            case .finished(let summary):
                if summary.isComplete {
                    lastSync = Date()
                    defaults.set(lastSync, forKey: Self.lastSyncKey)
                    consecutiveFailures = 0
                } else {
                    registerFailure()
                }
                finishSync(result: describe(summary))
                return
            }
        }
        armReplyTimer()
    }

    private func save(_ file: ActivityFile) -> Bool {
        guard let store else { return false }
        do {
            try store.save(file)
            return true
        } catch {
            note("salvataggio di \(file.id) fallito: \(error.localizedDescription)")
            return false
        }
    }

    private func armReplyTimer() {
        guard sync?.isWaitingForBand == true else { return }
        armTimer(Timing.replyTimeout) { [weak self] in
            guard let self else { return }
            self.perform(self.sync?.handleTimeout() ?? [])
        }
    }

    private func finishSync(result: String) {
        replyTimer?.cancel()
        sync = nil
        lastResult = result
        note("sincronizzazione: \(result)")
        if cipher != nil {
            phase = .connected
        }
        Task {
            await importPending()
            endBackgroundTime()
        }
    }

    private func describe(_ summary: ActivitySync.Summary) -> String {
        var parts = ["\(summary.received) file ricevuti"]
        if summary.failed > 0 { parts.append("\(summary.failed) non arrivati") }
        if summary.kept > 0 { parts.append("\(summary.kept) lasciati sulla band (illeggibili o notte in corso)") }
        if summary.unsupported > 0 { parts.append("\(summary.unsupported) allenamenti lasciati sulla band") }
        if !summary.isComplete { parts.append("la band non ha risposto a un elenco") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Health

    /// Writes every file waiting on disk. Stops at the first file Health refuses,
    /// keeping it and the following ones for the next attempt.
    public func importPending() async {
        guard let store else { return }
        guard !isImporting else {
            // Files saved during the running import are taken by one more pass.
            importRequestedAgain = true
            return
        }
        isImporting = true
        defer { isImporting = false }
        repeat {
            importRequestedAgain = false
            await importOnce(from: store)
        } while importRequestedAgain
        try? store.removeImportedFiles(olderThan: Date().addingTimeInterval(-Timing.keepProcessedFiles))
    }

    /// When the user allows more data types, the files already imported are
    /// written again so that the newly allowed values reach Health too.
    private func requeueIfMoreTypesAllowed(_ store: ActivityFileStore) {
        guard configuration.writesToHealth, case .answered(let allowed, _) = healthAccess else { return }
        let previous = defaults.integer(forKey: Self.allowedTypesKey)
        defaults.set(allowed, forKey: Self.allowedTypesKey)
        // Version 2 writes every type and trusts only Health's own refusals:
        // files imported by the first version are written once more.
        let writerVersion = defaults.integer(forKey: Self.writerVersionKey)
        defaults.set(Self.writerVersion, forKey: Self.writerVersionKey)
        guard allowed > previous || writerVersion < Self.writerVersion else { return }
        do {
            try store.requeueImported()
            note("permessi di Salute ampliati: riscrivo i dati già scaricati")
        } catch {
            note("impossibile rimettere in coda i file già importati: \(error.localizedDescription)")
        }
    }

    private func importOnce(from store: ActivityFileStore) async {
        healthAccess = writer.access
        requeueIfMoreTypesAllowed(store)
        let switchedOff = writer.switchedOffTypes
        if configuration.writesToHealth, !switchedOff.isEmpty {
            note("secondo iOS il permesso è spento per \(switchedOff.joined(separator: ", ")): provo comunque")
        }
        let files = (try? store.pendingFiles()) ?? []
        pendingFileCount = files.count
        guard !files.isEmpty else { return }
        guard !configuration.writesToHealth || healthAccess != .notRequested else {
            note("\(files.count) file in attesa del permesso di Salute")
            return
        }
        var wroteToHealth = false
        defer { if wroteToHealth { onHealthDataWritten?() } }
        // Grows by one per file, so two summaries of one day imported together still differ.
        let firstRevision = Int(Date().timeIntervalSince1970) * 1000
        for (index, file) in files.enumerated() {
            let content: ActivityContent
            do {
                content = try ActivityContent.decode(file)
            } catch {
                note("file \(file.id) illeggibile (\(error)), messo da parte")
                try? store.markRejected(file.id)
                continue
            }
            let samples = HealthSamples.make(from: content, revision: firstRevision + index)
            var result = HealthStoreWriter.WriteResult()
            defer { if result.written > 0 { wroteToHealth = true } }
            if configuration.writesToHealth {
                do {
                    result = try await writer.write(samples)
                } catch {
                    note("Salute non scrivibile ora (\(error.localizedDescription)), riprovo più tardi")
                    break
                }
            }
            let refusals = result.refusals.isEmpty ? "" : ", Salute rifiuta: \(result.refusals.joined(separator: ", "))"
            note("\(file.id.kind): \(ContentDescription.describe(content)), \(result.written) valori scritti in Salute\(refusals)")
            if (try? store.markImported(file)) != true {
                importRequestedAgain = true
            }
        }
        pendingFileCount = ((try? store.pendingFiles()) ?? []).count
    }

    // MARK: - Session bookkeeping

    private func endSession() {
        replyTimer?.cancel()
        authenticator = nil
        cipher = nil
        sync = nil
        endBackgroundTime()
    }

    private func registerFailure() {
        consecutiveFailures += 1
        guard consecutiveFailures >= Timing.failuresBeforeBackoff else { return }
        pausedUntil = Date().addingTimeInterval(Timing.backoff)
        consecutiveFailures = 0
        note("troppi errori di fila: pausa di \(Int(Timing.backoff / 60)) minuti")
    }

    private func armTimer(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        replyTimer?.cancel()
        replyTimer = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func schedulePeriodicSync() {
        periodicSync?.cancel()
        let interval = configuration.minimumSyncInterval
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if self.isSyncDue { self.startSync() }
            }
        }
    }

    private func note(_ message: String) {
        log.add(message)
        recentLog = log.recentLines
    }

    // MARK: - Application state

    private func observeApplication() {
        #if canImport(UIKit)
        guard notificationObservers.isEmpty else { return }
        let names = [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification]
        notificationObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.importPending() }
                    if self.cipher == nil, self.authenticator == nil {
                        self.link?.reopenSession()
                    } else if self.isSyncDue {
                        self.startSync()
                    }
                }
            }
        }
        #endif
    }

    /// Asks the system for some extra seconds while a download runs in the background.
    private func beginBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "band-sync") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime() }
        }
        #endif
    }

    private func endBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}

/// Short descriptions of decoded files for the diary: counts only, no values.
enum ContentDescription {
    static func describe(_ content: ActivityContent) -> String {
        switch content {
        case .minutes(let minutes):
            let steps = minutes.compactMap(\.steps).reduce(0, +)
            let heartRates = minutes.compactMap(\.heartRate).count
            return "\(minutes.count) minuti, \(steps) passi, \(heartRates) battiti"
        case .summary:
            return "riepilogo del giorno"
        case .sleep(let session):
            let state = session.isFinished ? "concluso" : "in corso"
            return "sonno di \(Int(session.wakeTime.timeIntervalSince(session.bedTime) / 60)) min, "
                + "\(session.segments.count) fasi, \(state)"
        case .manualSamples(let samples):
            return "\(samples.count) misure manuali"
        case .empty:
            return "vuoto"
        }
    }
}
