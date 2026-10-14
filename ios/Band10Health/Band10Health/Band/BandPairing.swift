import Band10Kit
import Foundation
import os

/// Pairs a factory-reset band without Mi Fitness: opens a link session, runs the
/// local pairing sequence and stores the resulting auth key in the Keychain.
@MainActor
final class BandPairing: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false
    /// True while the band is waiting for the user to accept on its screen.
    @Published private(set) var needsConfirmationOnBand = false

    static let logFilename = "band-pairing.log"
    static let autoStartArgument = "--band-pair"
    static var shouldAutoStart: Bool { CommandLine.arguments.contains(autoStartArgument) }
    /// Experiment: offer the local key exchange even to a band that asks for the server mode.
    static let forceLocalArgument = "--band-force-local"

    /// Long enough to find the band and for the user to accept on its screen.
    private static let timeout: Duration = .seconds(120)
    /// The band does not check the user id; pairing just needs a stable value.
    private static let localUserID = "0000000000"
    private static let appDeviceIDDefaultsKey = "band.appDeviceID"
    private static let phoneModel = "iPhone"

    private let logger = Logger(subsystem: "com.band10health.app", category: "BandPairing")
    private var session: BandSession?
    private var binder: LocalBinder?
    private var timeoutTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        needsConfirmationOnBand = false
        log("associazione avviata")

        let forcesLocal = CommandLine.arguments.contains(Self.forceLocalArgument)
        binder = LocalBinder(identity: Self.makeIdentity(), triesLocalModeAnyway: forcesLocal)
        log("modalità locale forzata: \(forcesLocal)")
        let session = BandSession { [weak self] event in self?.handle(event) }
        self.session = session
        session.start()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.session?.close("tempo scaduto dopo \(Self.timeout)")
        }
    }

    private func handle(_ event: BandSessionEvent) {
        switch event {
        case .log(let message):
            log(message)
        case .sessionOpen:
            log("sessione aperta, avvio la sequenza")
            perform(binder?.start() ?? [])
        case .payload(let payload):
            handle(payload)
        case .closed(let reason):
            timeoutTask?.cancel()
            session = nil
            binder = nil
            needsConfirmationOnBand = false
            log("FINE: \(reason)")
            isRunning = false
        }
    }

    private func handle(_ payload: XiaomiDataPayload) {
        guard payload.channel == .command, payload.opcode == .plaintext else {
            log("ignorato pacchetto \(payload.channel) \(payload.opcode) di \(payload.body.count) byte")
            return
        }
        do {
            let reply = try BindingReply.parse(payload.body)
            log("risposta: \(Self.describe(reply))")
            perform(binder?.handle(reply) ?? [])
        } catch {
            log("risposta non interpretabile: \(error)")
        }
    }

    private func perform(_ actions: [LocalBinder.Action]) {
        for action in actions {
            switch action {
            case .send(let command):
                session?.send(XiaomiDataPayload(channel: .command, opcode: .plaintext, body: command))
            case .askUserToConfirmOnBand:
                needsConfirmationOnBand = true
                log("ATTESA: conferma l'associazione sullo schermo della band")
            case .completed(let authKey, let macAddress):
                store(authKey, macAddress: macAddress)
            case .failed(let failure):
                session?.close("associazione fallita: \(failure)")
            }
        }
    }

    private func store(_ authKey: Data, macAddress: String) {
        do {
            try BandKeychain.saveAuthKey(authKey)
            // The key itself is never logged.
            log("chiave di \(authKey.count) byte salvata nel Portachiavi, band \(macAddress)")
            session?.close("associazione completata")
        } catch {
            session?.close("chiave ottenuta ma non salvata: \(error)")
        }
    }

    private static func makeIdentity() -> LocalBinder.Identity {
        LocalBinder.Identity(
            userID: localUserID,
            appDeviceID: storedAppDeviceID(),
            systemVersion: Float(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            phoneModel: phoneModel
        )
    }

    /// A random identifier for this installation; not a secret.
    private static func storedAppDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: appDeviceIDDefaultsKey) {
            return existing
        }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(created, forKey: appDeviceIDDefaultsKey)
        return created
    }

    /// Summaries only: public keys, randoms and signatures are left out of the log.
    private static func describe(_ reply: BindingReply) -> String {
        switch reply {
        case .bindInfo(let info):
            "info associazione: modalità \(info.verifyMode), conferma \(info.outOfBandMode), mac \(info.macAddress)"
        case .deviceVerify:
            "chiave pubblica e firma della band"
        case .confirmResult(let confirmed):
            "conferma dalla band: \(confirmed)"
        case .error(let code):
            "codice \(code)"
        case .acknowledged:
            "ricevuto"
        }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lines = lines + [message]
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("cartella Documents non disponibile")
            return
        }
        do {
            let text = lines.joined(separator: "\n") + "\n"
            try text.write(to: folder.appendingPathComponent(Self.logFilename), atomically: true, encoding: .utf8)
        } catch {
            logger.error("scrittura log fallita: \(error.localizedDescription, privacy: .public)")
        }
    }
}
