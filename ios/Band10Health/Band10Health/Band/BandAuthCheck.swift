import Band10Kit
import Foundation
import os

/// Proves the stored auth key works: runs the encrypted handshake with the band,
/// then asks for device info and battery over the encrypted channel.
@MainActor
final class BandAuthCheck: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false

    static let logFilename = "band-authcheck.log"
    static let autoStartArgument = "--band-auth-check"
    static var shouldAutoStart: Bool { CommandLine.arguments.contains(autoStartArgument) }
    /// `--band-set-authkey <32 hex chars>` stores the key in the Keychain at launch.
    static let setKeyArgument = "--band-set-authkey"

    private static let timeout: Duration = .seconds(25)
    private static let phoneName = "iPhone"
    private static let fallbackRegion = "IT"
    private static let expectedReplies = 2
    /// "TX " plus the 8-byte frame header and 8 payload bytes, in hex.
    private static let frameDumpPrefixLength = 3 + 32

    private let logger = Logger(subsystem: "com.band10health.app", category: "BandAuthCheck")
    private var session: BandSession?
    private var authenticator: Authenticator?
    private var cipher: SessionCipher?
    private var repliesReceived = 0
    private var timeoutTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        repliesReceived = 0
        cipher = nil
        log("verifica chiave avviata")
        storeKeyFromLaunchArgumentIfPresent()

        do {
            guard let authKey = try BandKeychain.loadAuthKey() else {
                finish("nessuna chiave nel Portachiavi")
                return
            }
            authenticator = try Authenticator(authKey: authKey, companion: Self.makeCompanion())
        } catch {
            finish("chiave non utilizzabile: \(error)")
            return
        }

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
            // Frame dumps are cut to the header and the first payload bytes.
            let isFrameDump = message.hasPrefix("TX ") || message.hasPrefix("RX ")
            log(isFrameDump ? String(message.prefix(Self.frameDumpPrefixLength)) : message)
        case .sessionOpen:
            log("sessione aperta, avvio l'autenticazione")
            perform(authenticator?.start() ?? [])
        case .payload(let payload):
            handle(payload)
        case .closed(let reason):
            finish(reason)
        }
    }

    private func handle(_ payload: XiaomiDataPayload) {
        guard payload.channel == .command else {
            log("ignorato pacchetto sul canale \(payload.channel) di \(payload.body.count) byte")
            return
        }
        switch payload.opcode {
        case .plaintext:
            handleHandshake(payload.body)
        case .encrypted:
            handleEncrypted(payload.body)
        }
    }

    private func handleHandshake(_ body: Data) {
        do {
            let reply = try AuthReply.parse(body)
            log("risposta autenticazione: \(Self.describe(reply))")
            perform(authenticator?.handle(reply) ?? [])
        } catch {
            log("risposta di autenticazione non interpretabile: \(error)")
        }
    }

    private func handleEncrypted(_ body: Data) {
        guard let cipher else {
            log("pacchetto cifrato di \(body.count) byte prima dell'autenticazione, ignorato")
            return
        }
        do {
            let reply = try SystemReply.parse(try cipher.decrypt(body))
            log("risposta cifrata: \(Self.describe(reply))")
            if case .other = reply { return }
            repliesReceived += 1
            if repliesReceived >= Self.expectedReplies {
                session?.close("chiave verificata: la band risponde ai comandi cifrati")
            }
        } catch {
            log("pacchetto cifrato non interpretabile (\(body.count) byte): \(error)")
        }
    }

    private func perform(_ actions: [Authenticator.Action]) {
        for action in actions {
            switch action {
            case .send(let command):
                session?.send(XiaomiDataPayload(channel: .command, opcode: .plaintext, body: command))
            case .authenticated(let cipher):
                self.cipher = cipher
                log("AUTENTICATO: la chiave è quella giusta")
                sendEncrypted(SystemCommand.deviceInfoRequest)
                sendEncrypted(SystemCommand.batteryRequest)
            case .failed(let failure):
                session?.close("autenticazione fallita: \(failure)")
            }
        }
    }

    private func sendEncrypted(_ command: Data) {
        guard let cipher else { return }
        do {
            let body = try cipher.encrypt(command)
            session?.send(XiaomiDataPayload(channel: .command, opcode: .encrypted, body: body))
        } catch {
            log("cifratura fallita: \(error)")
        }
    }

    private func finish(_ reason: String) {
        timeoutTask?.cancel()
        session = nil
        authenticator = nil
        cipher = nil
        log("FINE: \(reason)")
        isRunning = false
    }

    private func storeKeyFromLaunchArgumentIfPresent() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: Self.setKeyArgument), arguments.indices.contains(index + 1) else {
            return
        }
        guard let key = Data(hexEncoded: arguments[index + 1]), key.count == SessionKeys.authKeyLength else {
            log("chiave passata all'avvio non valida, ignorata")
            return
        }
        do {
            try BandKeychain.saveAuthKey(key)
            log("chiave di \(key.count) byte salvata nel Portachiavi")
        } catch {
            log("salvataggio della chiave fallito: \(error)")
        }
    }

    private static func makeCompanion() -> Authenticator.Companion {
        Authenticator.Companion(
            systemVersion: Float(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            phoneName: phoneName,
            region: (Locale.current.region?.identifier ?? fallbackRegion).uppercased()
        )
    }

    private static func describe(_ reply: AuthReply) -> String {
        switch reply {
        case .deviceVerify: "numero casuale e prova della band"
        case .accepted: "accettata"
        case .rejected(let subtype, let status): "rifiutata (sottotipo \(subtype), stato \(status))"
        }
    }

    private static func describe(_ reply: SystemReply) -> String {
        switch reply {
        case .deviceInfo(let serialNumber, let firmware, let model):
            "modello \(model), firmware \(firmware), seriale \(serialNumber)"
        case .battery(let level):
            "batteria \(level)%"
        case .other(let subtype):
            "altro comando di sistema (sottotipo \(subtype))"
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

private extension Data {
    /// Parses an even-length hex string; nil on any non-hex character.
    init?(hexEncoded text: String) {
        let digits = Array(text)
        guard digits.count.isMultiple(of: 2) else { return nil }
        let bytes = stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        guard !bytes.contains(nil) else { return nil }
        self.init(bytes.compactMap { $0 })
    }
}
