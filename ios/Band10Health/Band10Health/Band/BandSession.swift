import Band10Kit
@preconcurrency import CoreBluetooth
import Foundation

enum BandSessionEvent {
    case log(String)
    /// The band accepted the session request; commands can be sent.
    case sessionOpen
    case payload(XiaomiDataPayload)
    case closed(String)
}

/// Moves bytes between CoreBluetooth and `XiaomiLink`: finds the band among the
/// peripherals already connected to the phone, subscribes to its transport
/// characteristic, opens the link session and delivers decoded payloads.
@MainActor
final class BandSession: NSObject {
    private static let service = CBUUID(string: "FE95")
    private static let receiveCharacteristic = CBUUID(string: "005E")
    private static let transmitCharacteristic = CBUUID(string: "005F")
    private static let sessionStartOpcode: UInt8 = 2
    private static let sessionStopOpcode: UInt8 = 4
    /// How long to wait for the band to confirm the stop before opening anyway.
    private static let stopConfirmationWait: Duration = .milliseconds(1500)
    private static let bandNameFragment = "band"
    /// Remembers the band between launches so it can be reconnected without scanning.
    private static let identifierDefaultsKey = "band.peripheralIdentifier"

    private let onEvent: (BandSessionEvent) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var link = XiaomiLink()
    private var isClosed = false
    private var hasRequestedSession = false

    init(onEvent: @escaping (BandSessionEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func send(_ payload: XiaomiDataPayload) {
        do {
            write(try link.dataFrame(payload))
        } catch {
            close("pacchetto non codificabile: \(error)")
        }
    }

    func close(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        central?.stopScan()
        // Leave the band without a half-open session for the next connection.
        if transmit != nil, let stopFrame = try? link.sessionStopFrame() {
            write(stopFrame)
        }
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        onEvent(.closed(reason))
    }

    private func write(_ frame: Data) {
        guard let peripheral, let transmit else {
            close("canale di scrittura non disponibile")
            return
        }
        let chunkSize = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let chunks = stride(from: 0, to: frame.count, by: chunkSize).map { start in
            frame.subdata(in: start..<min(start + chunkSize, frame.count))
        }
        onEvent(.log("TX \(frame.hexString)"))
        chunks.forEach { peripheral.writeValue($0, for: transmit, type: .withoutResponse) }
    }

    private func handle(_ output: XiaomiLink.Output) {
        output.framesToSend.forEach(write)
        for event in output.events {
            switch event {
            case .sessionConfig(let opcode):
                onEvent(.log("sessione: opcode \(opcode)"))
                if opcode == Self.sessionStartOpcode {
                    onEvent(.sessionOpen)
                } else if opcode == Self.sessionStopOpcode {
                    requestSession()
                }
            case .payload(let payload):
                onEvent(.payload(payload))
            case .acknowledged(let sequence):
                onEvent(.log("ack \(sequence)"))
            case .rejected(let sequence):
                onEvent(.log("nack \(sequence)"))
            case .discarded(let byteCount, let reason):
                onEvent(.log("scartati \(byteCount) byte: \(reason)"))
            case .malformedPayload(let sequence, let reason):
                onEvent(.log("payload illeggibile nel pacchetto \(sequence): \(reason)"))
            }
        }
    }
}

// CoreBluetooth calls back on the main queue passed to `CBCentralManager(delegate:queue:)`.
extension BandSession: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown, central.state != .resetting {
                close("Bluetooth non disponibile (stato \(central.state.rawValue))")
            }
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service])
        if let band = connected.first(where: { Self.isBand(name: $0.name) }) {
            connect(to: band, using: central)
            return
        }
        if let known = Self.storedIdentifier(),
           let band = central.retrievePeripherals(withIdentifiers: [known]).first {
            // A pending connection completes as soon as the band comes into range.
            onEvent(.log("band nota ma non connessa, attendo che si ricolleghi"))
            connect(to: band, using: central)
            return
        }
        // First contact, or a factory-reset band: look for its advertisement.
        onEvent(.log("band non connessa al telefono, la cerco"))
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
        // A paired band advertises without a name, only with Xiaomi service data.
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let looksLikeBand = Self.isBand(name: name) || serviceData[Self.service] != nil
        guard self.peripheral == nil, isConnectable, looksLikeBand else { return }
        central.stopScan()
        connect(to: peripheral, using: central)
    }

    private func connect(to band: CBPeripheral, using central: CBCentralManager) {
        peripheral = band
        band.delegate = self
        onEvent(.log("connessione a \(band.name ?? "band")"))
        central.connect(band)
    }

    /// `--band-identifier <uuid>` seeds the identifier before the first connection.
    private static let identifierArgument = "--band-identifier"

    private static func storedIdentifier() -> UUID? {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: identifierArgument), arguments.indices.contains(index + 1),
           let seeded = UUID(uuidString: arguments[index + 1]) {
            return seeded
        }
        return UserDefaults.standard.string(forKey: identifierDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    private static func isBand(name: String?) -> Bool {
        (name ?? "").lowercased().contains(bandNameFragment)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.identifierDefaultsKey)
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        close("connessione fallita: \(error?.localizedDescription ?? "errore sconosciuto")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        close("disconnesso: \(error?.localizedDescription ?? "senza errore")")
    }
}

extension BandSession: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            close("servizio FE95 non trovato")
            return
        }
        peripheral.discoverCharacteristics([Self.receiveCharacteristic, Self.transmitCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let receive = characteristics.first(where: { $0.uuid == Self.receiveCharacteristic }),
              let transmit = characteristics.first(where: { $0.uuid == Self.transmitCharacteristic })
        else {
            close("caratteristiche di trasporto non trovate")
            return
        }
        self.transmit = transmit
        peripheral.setNotifyValue(true, for: receive)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            close("notifiche non attivabili: \(error.localizedDescription)")
            return
        }
        onEvent(.log("notifiche attive, chiudo eventuali sessioni rimaste aperte"))
        if let stopFrame = try? link.sessionStopFrame() {
            write(stopFrame)
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.stopConfirmationWait)
            self?.requestSession()
        }
    }

    private func requestSession() {
        guard !hasRequestedSession, !isClosed else { return }
        hasRequestedSession = true
        onEvent(.log("apro la sessione"))
        do {
            write(try link.sessionRequestFrame())
        } catch {
            close("richiesta di sessione non codificabile: \(error)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        onEvent(.log("RX \(value.hexString)"))
        handle(link.receive(value))
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
