// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiSppPacketV2), AGPL-3.0.

import Foundation

/// Checksum carried in every frame header. It is the standard CRC-16/ARC
/// (reflected polynomial 0x8005, initial value 0) computed over the payload only.
public enum XiaomiChecksum {
    private static let reflectedPolynomial: UInt16 = 0xA001
    private static let bitsPerByte = 8

    public static func crc16(_ payload: Data) -> UInt16 {
        payload.reduce(UInt16(0)) { crc, byte in
            (0..<bitsPerByte).reduce(crc ^ UInt16(byte)) { value, _ in
                value & 1 == 1 ? (value >> 1) ^ reflectedPolynomial : value >> 1
            }
        }
    }
}
