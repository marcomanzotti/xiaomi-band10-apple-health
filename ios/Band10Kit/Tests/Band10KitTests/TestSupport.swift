import Foundation

extension Data {
    /// Builds test fixtures from a hex string; traps on malformed input because a
    /// broken fixture is a programming error in the test itself.
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "hex fixture must have an even length")
        let digits = Array(hex)
        let bytes = stride(from: 0, to: digits.count, by: 2).map { index -> UInt8 in
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
                preconditionFailure("invalid hex fixture: \(hex)")
            }
            return byte
        }
        self.init(bytes)
    }
}
