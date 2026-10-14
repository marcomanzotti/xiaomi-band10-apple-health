@preconcurrency import CoreBluetooth
import Foundation
import os

/// Read-only Bluetooth survey of the band: finds it, lists its GATT services and
/// characteristics, and reads the standard identity fields. It never writes to the
/// band and never subscribes to anything, so it cannot disturb Mi Fitness.
@MainActor
final class BandProbe: NSObject, ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false

    static let logFilename = "band-probe.log"

    private static let xiaomiService = CBUUID(string: "FE95")
    /// Services asked of the system when looking for an already-connected band.
    private static let connectedLookupServices = [
        xiaomiService, CBUUID(string: "180A"), CBUUID(string: "180D"), CBUUID(string: "180F"),
    ]
    private static let scanDuration: Duration = .seconds(15)
    private static let readSettleDuration: Duration = .seconds(3)
    private static let identityCharacteristics: [CBUUID: String] = [
        CBUUID(string: "2A00"): "device_name",
        CBUUID(string: "2A24"): "model_number",
        CBUUID(string: "2A25"): "serial_number",
        CBUUID(string: "2A26"): "firmware_revision",
        CBUUID(string: "2A27"): "hardware_revision",
        CBUUID(string: "2A28"): "software_revision",
        CBUUID(string: "2A29"): "manufacturer",
        CBUUID(string: "2A19"): "battery_level",
    ]

    private let logger = Logger(subsystem: "com.band10health.app", category: "BandProbe")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var servicesAwaitingCharacteristics = 0
    private var scanTimeout: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        lines = []
        isRunning = true
        log("sonda avviata")
        if let central, central.state == .poweredOn {
            findBand(using: central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    // MARK: - Steps

    private func findBand(using central: CBCentralManager) {
        let connected = central.retrieveConnectedPeripherals(withServices: Self.connectedLookupServices)
        log("periferiche già connesse al sistema: \(connected.count)")
        connected.forEach { log("  connessa: \($0.name ?? "senza nome") \($0.identifier.uuidString)") }

        if let band = connected.first(where: { Self.looksLikeBand($0.name) }) {
            connect(to: band, using: central)
            return
        }

        log("nessuna band tra le connesse, scansione per \(Self.scanDuration)")
        central.scanForPeripherals(withServices: nil)
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.scanDuration)
            guard !Task.isCancelled else { return }
            self?.finish("nessuna band trovata nella scansione")
        }
    }

    private func connect(to band: CBPeripheral, using central: CBCentralManager) {
        scanTimeout?.cancel()
        central.stopScan()
        peripheral = band
        band.delegate = self
        log("connessione a \(band.name ?? "senza nome") \(band.identifier.uuidString)")
        central.connect(band)
    }

    private func finish(_ reason: String) {
        scanTimeout?.cancel()
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        log("FINE: \(reason)")
        isRunning = false
    }

    private static func looksLikeBand(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.contains("band") || name.contains("xiaomi")
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lines = lines + [message]
        persist()
    }

    private func persist() {
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

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResp"),
            (.notify, "notify"), (.indicate, "indicate"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    private static func describe(_ value: Data) -> String {
        let hex = value.map { String(format: "%02x", $0) }.joined()
        let text = String(data: value, encoding: .utf8).map { " \"\($0)\"" } ?? ""
        return hex + text
    }
}

// MARK: - CBCentralManagerDelegate

// CoreBluetooth calls back on the main queue passed to `CBCentralManager(delegate:queue:)`.
extension BandProbe: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("stato bluetooth: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            findBand(using: central)
        case .unauthorized:
            finish("permesso Bluetooth negato")
        case .poweredOff:
            finish("Bluetooth spento")
        case .unsupported:
            finish("Bluetooth LE non supportato")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard serviceData[Self.xiaomiService] != nil || Self.looksLikeBand(name) else { return }

        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
        let payload = serviceData[Self.xiaomiService].map(Self.describe) ?? "-"
        log("annuncio: \(name ?? "senza nome") rssi=\(RSSI) connettibile=\(connectable) fe95=\(payload)")
        if connectable, self.peripheral == nil {
            connect(to: peripheral, using: central)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connesso, mtu scrittura=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("connessione fallita: \(error?.localizedDescription ?? "errore sconosciuto")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isRunning else { return }
        finish("disconnesso: \(error?.localizedDescription ?? "senza errore")")
    }
}

// MARK: - CBPeripheralDelegate

extension BandProbe: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finish("scoperta servizi fallita: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        log("servizi: \(services.count)")
        servicesAwaitingCharacteristics = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        if services.isEmpty {
            finish("nessun servizio esposto")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        log("SERVIZIO \(service.uuid.uuidString)\(error.map { " errore: \($0.localizedDescription)" } ?? "")")
        for characteristic in service.characteristics ?? [] {
            log("  CARATT \(characteristic.uuid.uuidString) [\(Self.describe(characteristic.properties))]")
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }

        servicesAwaitingCharacteristics -= 1
        guard servicesAwaitingCharacteristics == 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.readSettleDuration)
            self?.finish("mappa GATT completa")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let label = Self.identityCharacteristics[characteristic.uuid] ?? characteristic.uuid.uuidString
        if let error {
            log("  lettura \(label) fallita: \(error.localizedDescription)")
        } else {
            log("  \(label) = \(Self.describe(characteristic.value ?? Data()))")
        }
    }
}
