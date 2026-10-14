import Band10Kit
import Foundation
import os

/// First live exchange with the band: opens a link session and asks for the bind
/// info. A band that is already paired answers with error code 1, which is enough
/// to prove that framing, session and command encoding work end to end.
@MainActor
final class BandBindCheck: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false

    static let logFilename = "band-bindcheck.log"
    static let autoStartArgument = "--band-bind-check"
    static var shouldAutoStart: Bool { CommandLine.arguments.contains(autoStartArgument) }

    private static let timeout: Duration = .seconds(15)
    /// The band only receives a digest of this; any stable value works for the query.
    private static let placeholderUserID = "0"
    private static let alreadyBoundCode = 1

    private let logger = Logger(subsystem: "com.band10health.app", category: "BandBindCheck")
    private var session: BandSession?
    private var timeoutTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        log("verifica associazione avviata")

        let session = BandSession { [weak self] event in self?.handle(event) }
        self.session = session
        session.start()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.session?.close("nessuna risposta entro \(Self.timeout)")
        }
    }

    private func handle(_ event: BandSessionEvent) {
        switch event {
        case .log(let message):
            log(message)
        case .sessionOpen:
            log("sessione aperta, chiedo lo stato dell'associazione")
            let request = BindingCommand.bindInfoRequest(userID: Self.placeholderUserID)
            session?.send(XiaomiDataPayload(channel: .command, opcode: .plaintext, body: request))
        case .payload(let payload):
            handle(payload)
        case .closed(let reason):
            timeoutTask?.cancel()
            session = nil
            log("FINE: \(reason)")
            isRunning = false
        }
    }

    private func handle(_ payload: XiaomiDataPayload) {
        guard payload.channel == .command, payload.opcode == .plaintext else {
            log("ignorato pacchetto \(payload.channel) \(payload.opcode) di \(payload.body.count) byte (traffico di un'altra app)")
            return
        }
        do {
            let reply = try BindingReply.parse(payload.body)
            log("risposta: \(describe(reply))")
            session?.close("risposta ricevuta")
        } catch {
            log("risposta non interpretabile: \(error)")
        }
    }

    private func describe(_ reply: BindingReply) -> String {
        switch reply {
        case .error(let code) where code == Self.alreadyBoundCode:
            return "band già associata (codice 1)"
        case .error(let code):
            return "errore \(code)"
        case .bindInfo(let info):
            return "modalità \(info.verifyMode), conferma \(info.outOfBandMode), mac \(info.macAddress)"
        case .deviceVerify, .confirmResult, .acknowledged:
            return "inattesa: \(reply)"
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
