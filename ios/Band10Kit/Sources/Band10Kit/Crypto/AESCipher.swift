// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Protocol behaviour derived from Gadgetbridge (XiaomiAuthService), AGPL-3.0.

import CommonCrypto
import Foundation

public enum AESCipherError: Error, Equatable, Sendable {
    case invalidKeyLength(Int)
    case invalidCounterLength(Int)
    case invalidNonceLength(Int)
    case messageTooShort(Int)
    case messageTooLong(Int)
    case associatedDataTooLong(Int)
    case authenticationFailed
    case cryptorFailure(Int32)
}

/// The two AES-128 modes the band uses: plain counter mode for transport payloads
/// and CCM (12-byte nonce, 4-byte tag, no associated data) inside the handshake.
/// CryptoKit offers neither, so both are built on CommonCrypto's block cipher.
///
/// The band's design limits what these give: counter mode carries no integrity
/// check, and a 4-byte tag is weak. Treat everything decrypted here as untrusted
/// input and validate it when parsing.
public enum AESCipher {
    public static let keyLength = kCCKeySizeAES128
    public static let blockLength = kCCBlockSizeAES128
    public static let ccmNonceLength = 12
    public static let ccmTagLength = 4

    /// Bytes of the counter block that CCM leaves for the block counter (RFC 3610 "L").
    private static let ccmLengthFieldSize = blockLength - 1 - ccmNonceLength
    static let ccmMaxMessageLength = (1 << (8 * ccmLengthFieldSize)) - 1
    /// Longest associated data the short (two-byte) length encoding of RFC 3610 can describe.
    static let ccmMaxAssociatedDataLength = 0xFEFF
    private static let ccmAssociatedDataFlag: UInt8 = 0x40
    private static let ccmTagMaskCounter = 0
    private static let ccmFirstPayloadCounter = 1

    // MARK: - Counter mode

    /// Encrypts or decrypts (the operation is symmetric) with a big-endian 128-bit counter.
    public static func counterMode(
        _ message: Data,
        key: Data,
        initialCounter: Data
    ) throws(AESCipherError) -> Data {
        guard initialCounter.count == blockLength else {
            throw .invalidCounterLength(initialCounter.count)
        }
        let blockCount = (message.count + blockLength - 1) / blockLength
        let counters = (0..<blockCount).reduce(into: Data(capacity: blockCount * blockLength)) { blocks, index in
            blocks.append(contentsOf: adding(index, toCounter: [UInt8](initialCounter)))
        }
        let keystream = try blockEncrypt(counters, key: key, chained: false)
        return Data(zip(message, keystream).map { $0 ^ $1 })
    }

    // MARK: - CCM

    /// Encrypts `plaintext` and appends the 4-byte tag. `associatedData` is
    /// authenticated by the tag but not included in the output.
    public static func ccmSeal(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        associatedData: Data = Data()
    ) throws(AESCipherError) -> Data {
        try validateCCM(nonce: nonce, messageLength: plaintext.count, associatedDataLength: associatedData.count)
        let firstCounter = ccmCounterBlock(nonce: nonce, index: ccmFirstPayloadCounter)
        let ciphertext = try counterMode(plaintext, key: key, initialCounter: firstCounter)
        let tag = try ccmTag(plaintext, key: key, nonce: nonce, associatedData: associatedData)
        return ciphertext + tag
    }

    /// Verifies the trailing 4-byte tag and returns the plaintext; throws
    /// `authenticationFailed` without releasing any plaintext if it does not match.
    public static func ccmOpen(
        _ sealed: Data,
        key: Data,
        nonce: Data,
        associatedData: Data = Data()
    ) throws(AESCipherError) -> Data {
        guard sealed.count >= ccmTagLength else {
            throw .messageTooShort(sealed.count)
        }
        let ciphertext = Data(sealed.dropLast(ccmTagLength))
        let receivedTag = Data(sealed.suffix(ccmTagLength))
        try validateCCM(nonce: nonce, messageLength: ciphertext.count, associatedDataLength: associatedData.count)

        let firstCounter = ccmCounterBlock(nonce: nonce, index: ccmFirstPayloadCounter)
        let plaintext = try counterMode(ciphertext, key: key, initialCounter: firstCounter)
        let expectedTag = try ccmTag(plaintext, key: key, nonce: nonce, associatedData: associatedData)
        guard constantTimeEquals(receivedTag, expectedTag) else {
            throw .authenticationFailed
        }
        return plaintext
    }

    private static func validateCCM(
        nonce: Data,
        messageLength: Int,
        associatedDataLength: Int
    ) throws(AESCipherError) {
        guard nonce.count == ccmNonceLength else {
            throw .invalidNonceLength(nonce.count)
        }
        guard messageLength <= ccmMaxMessageLength else {
            throw .messageTooLong(messageLength)
        }
        guard associatedDataLength <= ccmMaxAssociatedDataLength else {
            throw .associatedDataTooLong(associatedDataLength)
        }
    }

    /// CBC-MAC over `B0 || length-prefixed associated data || message`, each part
    /// zero-padded to a block boundary, masked with the first keystream block.
    private static func ccmTag(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        associatedData: Data
    ) throws(AESCipherError) -> Data {
        let tagField = UInt8((ccmTagLength - 2) / 2) << 3
        let associatedDataFlag = associatedData.isEmpty ? 0 : ccmAssociatedDataFlag
        let flags = associatedDataFlag | tagField | UInt8(ccmLengthFieldSize - 1)
        let firstBlock = Data([flags]) + nonce + bigEndianBytes(plaintext.count, width: ccmLengthFieldSize)
        let authenticated = associatedData.isEmpty
            ? Data()
            : zeroPadded(bigEndianBytes(associatedData.count, width: 2) + associatedData)

        let chained = try blockEncrypt(firstBlock + authenticated + zeroPadded(plaintext), key: key, chained: true)
        let mac = chained.suffix(blockLength).prefix(ccmTagLength)
        let mask = try blockEncrypt(ccmCounterBlock(nonce: nonce, index: ccmTagMaskCounter), key: key, chained: false)
        return Data(zip(mac, mask).map { $0 ^ $1 })
    }

    private static func ccmCounterBlock(nonce: Data, index: Int) -> Data {
        Data([UInt8(ccmLengthFieldSize - 1)]) + nonce + bigEndianBytes(index, width: ccmLengthFieldSize)
    }

    // MARK: - Primitives

    /// AES-128 over whole blocks: independent blocks (ECB) or chained with a zero IV (CBC).
    private static func blockEncrypt(_ blocks: Data, key: Data, chained: Bool) throws(AESCipherError) -> Data {
        guard key.count == keyLength else {
            throw .invalidKeyLength(key.count)
        }
        guard !blocks.isEmpty else {
            return Data()
        }

        let options = chained ? CCOptions(0) : CCOptions(kCCOptionECBMode)
        let zeroIV = [UInt8](repeating: 0, count: blockLength)
        var output = [UInt8](repeating: 0, count: blocks.count)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            blocks.withUnsafeBytes { inputBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                    keyBytes.baseAddress, keyBytes.count, zeroIV,
                    inputBytes.baseAddress, inputBytes.count,
                    &output, output.count, &written
                )
            }
        }
        guard status == kCCSuccess, written == blocks.count else {
            throw .cryptorFailure(status)
        }
        return Data(output)
    }

    /// Adds `offset` to a big-endian counter block, wrapping on overflow.
    private static func adding(_ offset: Int, toCounter counter: [UInt8]) -> [UInt8] {
        var bytes = counter
        var carry = offset
        for position in bytes.indices.reversed() {
            let sum = Int(bytes[position]) + (carry & 0xFF)
            bytes[position] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
        }
        return bytes
    }

    private static func zeroPadded(_ data: Data) -> Data {
        data + Data(count: (blockLength - data.count % blockLength) % blockLength)
    }

    private static func bigEndianBytes(_ value: Int, width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
