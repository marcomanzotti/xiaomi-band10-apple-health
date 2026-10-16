// Band10Sync — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.

import Band10Kit
@preconcurrency import CoreBluetooth
import Foundation

enum BandLinkEvent {
    case log(String)
    /// Bluetooth is off, unauthorised or unsupported.
    case unavailable(String)
    /// Waiting for the band to come into range; it connects by itself.
    case waitingForBand
    /// The band accepted the session request; commands can be sent.
    case sessionOpen
    case payload(XiaomiDataPayload)
    case disconnected(String)
}

/// Moves bytes between CoreBluetooth and `XiaomiLink`, and keeps the connection
/// alive for good: after every disconnection it asks the system to reconnect as
/// soon as the band is back, which also works while the app is in the background
/// or was closed by the system.
@MainActor
final class BandLink: NSObject {
    private static let service = CBUUID(string: "FE95")
    private static let receiveCharacteristic = CBUUID(string: "005E")
    private static let transmitCharacteristic = CBUUID(string: "005F")
    private static let sessionStartOpcode: UInt8 = 2
    private static let sessionStopOpcode: UInt8 = 4
    /// How long to wait for the band to confirm the stop before opening anyway.
    private static let stopConfirmationWait: Duration = .milliseconds(1500)
    /// The system sometimes never reports that it can take more writes.
    private static let writeRetryWait: Duration = .milliseconds(200)
    private static let bandNameFragment = "band"

    private let restoreIdentifier: String
    private let identifierDefaultsKey: String
    private let defaults: UserDefaults
    private let onEvent: (BandLinkEvent) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var link = XiaomiLink()
    private var hasRequestedSession = false
    private var outgoing: [Data] = []
    private var writeRetry: Task<Void, Never>?
    private var sessionOpening: Task<Void, Never>?
    private var isStopped = false

    init(restoreIdentifier: String, defaults: UserDefaults = .standard, onEvent: @escaping (BandLinkEvent) -> Void) {
        self.restoreIdentifier = restoreIdentifier
        identifierDefaultsKey = "\(restoreIdentifier).peripheral"
        self.defaults = defaults
        self.onEvent = onEvent
    }

    func start() {
        guard central == nil else { return }
        isStopped = false
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        )
    }

    /// Closes the session and stops reconnecting.
    func stop() {
        isStopped = true
        central?.stopScan()
        if transmit != nil, let frame = try? link.sessionStopFrame() {
            enqueue(frame)
        }
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central = nil
        resetSession()
    }

    func send(_ payload: XiaomiDataPayload) {
        do {
            enqueue(try link.dataFrame(payload))
        } catch {
            onEvent(.log("cannot encode a packet: \(error)"))
        }
    }

    /// Ends the current session and opens a new one, for example after the band
    /// stopped answering.
    func reopenSession() {
        guard transmit != nil else { return }
        writeRetry?.cancel()
        outgoing = []
        link = XiaomiLink()
        hasRequestedSession = false
        closeLeftoverSessionThenOpen()
    }

    // MARK: - Writing

    private func enqueue(_ frame: Data) {
        guard let peripheral else { return }
        let size = peripheral.maximumWriteValueLength(for: .withoutResponse)
        outgoing += stride(from: 0, to: frame.count, by: size).map {
            frame.subdata(in: $0..<min($0 + size, frame.count))
        }
        flush(force: false)
    }

    /// Writes as much as the system accepts. Writes without response are dropped
    /// silently when the system's buffer is full, so the rest waits its turn.
    private func flush(force: Bool) {
        guard let peripheral, let transmit else {
            outgoing = []
            return
        }
        var mayForce = force
        while let next = outgoing.first, peripheral.canSendWriteWithoutResponse || mayForce {
            peripheral.writeValue(next, for: transmit, type: .withoutResponse)
            outgoing = Array(outgoing.dropFirst())
            mayForce = false
        }
        writeRetry?.cancel()
        guard !outgoing.isEmpty else { return }
        writeRetry = Task { [weak self] in
            try? await Task.sleep(for: Self.writeRetryWait)
            guard !Task.isCancelled else { return }
            self?.flush(force: true)
        }
    }

    // MARK: - Session

    private func closeLeftoverSessionThenOpen() {
        // A session left open by an earlier run of the app would make the band
        // ignore the new request.
        if let stopFrame = try? link.sessionStopFrame() {
            enqueue(stopFrame)
        }
        sessionOpening?.cancel()
        sessionOpening = Task { [weak self] in
            try? await Task.sleep(for: Self.stopConfirmationWait)
            guard !Task.isCancelled else { return }
            self?.requestSession()
        }
    }

    private func requestSession() {
        guard !hasRequestedSession, !isStopped, transmit != nil else { return }
        hasRequestedSession = true
        do {
            enqueue(try link.sessionRequestFrame())
        } catch {
            onEvent(.log("cannot encode the session request: \(error)"))
        }
    }

    private func resetSession() {
        writeRetry?.cancel()
        sessionOpening?.cancel()
        outgoing = []
        transmit = nil
        link = XiaomiLink()
        hasRequestedSession = false
    }

    private func handle(_ output: XiaomiLink.Output) {
        output.framesToSend.forEach(enqueue)
        for event in output.events {
            switch event {
            case .sessionConfig(let opcode):
                if opcode == Self.sessionStartOpcode {
                    onEvent(.sessionOpen)
                } else if opcode == Self.sessionStopOpcode {
                    requestSession()
                }
            case .payload(let payload):
                onEvent(.payload(payload))
            case .acknowledged:
                break
            case .rejected(let sequence):
                onEvent(.log("the band rejected packet \(sequence)"))
            case .discarded(let byteCount, let reason):
                onEvent(.log("dropped \(byteCount) bytes: \(reason)"))
            case .malformedPayload(let sequence, let reason):
                onEvent(.log("unreadable packet \(sequence): \(reason)"))
            }
        }
    }

    // MARK: - Finding the band

    private func connect(to band: CBPeripheral, using central: CBCentralManager) {
        peripheral = band
        band.delegate = self
        if band.state == .connected {
            band.discoverServices([Self.service])
        } else {
            // Never times out: completes whenever the band comes back into range.
            onEvent(.waitingForBand)
            central.connect(band)
        }
    }

    private var storedIdentifier: UUID? {
        defaults.string(forKey: identifierDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    private static func isBand(name: String?) -> Bool {
        (name ?? "").lowercased().contains(bandNameFragment)
    }
}

// CoreBluetooth calls back on the main queue passed to `CBCentralManager(delegate:queue:)`.
extension BandLink: @preconcurrency CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // The system relaunched the app for a Bluetooth event and hands back the band.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        if let band = restored.first {
            peripheral = band
            band.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown, central.state != .resetting {
                onEvent(.unavailable("Bluetooth unavailable (state \(central.state.rawValue))"))
            }
            return
        }
        if let peripheral {
            connect(to: peripheral, using: central)
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service])
        if let band = connected.first(where: { Self.isBand(name: $0.name) }) {
            connect(to: band, using: central)
            return
        }
        if let known = storedIdentifier, let band = central.retrievePeripherals(withIdentifiers: [known]).first {
            connect(to: band, using: central)
            return
        }
        // First contact: look for the band's advertisement.
        onEvent(.log("band never seen by this app, scanning for it"))
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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        defaults.set(peripheral.identifier.uuidString, forKey: identifierDefaultsKey)
        resetSession()
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reconnect(after: "connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reconnect(after: "disconnected: \(error?.localizedDescription ?? "no error")")
    }

    private func reconnect(after reason: String) {
        resetSession()
        onEvent(.disconnected(reason))
        guard !isStopped, let central, let peripheral else { return }
        central.connect(peripheral)
    }
}

extension BandLink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            // Disconnecting makes the system reconnect, and the discovery runs again.
            onEvent(.log("service FE95 not found, reconnecting"))
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.receiveCharacteristic, Self.transmitCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let receive = characteristics.first(where: { $0.uuid == Self.receiveCharacteristic }),
              let transmit = characteristics.first(where: { $0.uuid == Self.transmitCharacteristic })
        else {
            onEvent(.log("transport characteristics not found, reconnecting"))
            central?.cancelPeripheralConnection(peripheral)
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
            onEvent(.log("cannot enable notifications: \(error.localizedDescription)"))
            return
        }
        closeLeftoverSessionThenOpen()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        handle(link.receive(value))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush(force: false)
    }
}
