import Foundation
import Testing
@testable import Band10Kit

// Field numbers come from the protobuf serializers of Mi Fitness 3.46.1
// (Command, Account and the bind messages); expected bytes are hand-assembled
// from the protobuf wire format.

@Suite("Binding commands sent to the band")
struct BindingCommandTests {
    @Test("asks for the bind info with the MD5 of the user id")
    func buildsBindInfoRequest() {
        // md5("1234") = 81dc9bdb52d04dc20036dbd8313ed055
        let expected = Data(hex: "0801" + "1011" + "1a16" + "5a14" + "0800" + "1210" + "81dc9bdb52d04dc20036dbd8313ed055")

        #expect(BindingCommand.bindInfoRequest(userID: "1234") == expected)
    }

    @Test("sends the app identity and its public key")
    func buildsAppVerify() {
        let publicKey = Data(repeating: 0x01, count: 64)
        let expected = Data(hex: "0801" + "1012" + "1a49" + "8a0146" + "0a026162" + "1240") + publicKey

        #expect(BindingCommand.appVerify(appDeviceID: "ab", publicKey: publicKey) == expected)
    }

    @Test("confirms with the app random and its signature")
    func buildsAppConfirm() {
        let random = Data(repeating: 0x02, count: 16)
        let signature = Data(repeating: 0x03, count: 32)
        let expected = Data(hex: "0801" + "1013" + "1a37" + "9a0134" + "0a10") + random + Data(hex: "1220") + signature

        #expect(BindingCommand.appConfirm(appRandom: random, signature: signature) == expected)
    }

    @Test("wraps the sealed bind result")
    func buildsBindResult() {
        let expected = Data(hex: "0801" + "1019" + "1a08" + "ea0105" + "0a03aabbcc")

        #expect(BindingCommand.bindResult(sealed: Data(hex: "aabbcc")) == expected)
    }

    @Test("describes the phone in the bind result plaintext")
    func buildsBindResultPlaintext() {
        // 17.0 as a little-endian float is 00 00 88 41.
        let expected = Data(hex: "0a0175" + "120f" + "0801" + "1500008841" + "1a06") + Data("iPhone".utf8)

        let plaintext = BindingCommand.bindResultPlaintext(userID: "u", systemVersion: 17.0, phoneModel: "iPhone")

        #expect(plaintext == expected)
    }
}

@Suite("Binding replies from the band")
struct BindingReplyTests {
    @Test("reads the bind info and which pairing mode the band wants")
    func parsesBindInfo() throws {
        // Arrange: verifyMode 2, "a", mac "MC", "b", oobMode 3, "c".
        let info = "0802" + "120161" + "1a024d43" + "220162" + "2803" + "3a0163"
        let reply = Data(hex: "0801" + "1011" + "1a13" + "6211" + info)

        // Act
        let parsed = try BindingReply.parse(reply)

        // Assert
        #expect(parsed == .bindInfo(BindInfo(
            verifyMode: .local,
            outOfBandMode: 3,
            macAddress: "MC",
            unknownString2: "a",
            unknownString4: "b",
            unknownBytes6: Data(),
            unknownString7: "c"
        )))
    }

    @Test("maps verify mode 1 to the server-assisted mode and keeps unknown modes")
    func parsesOtherVerifyModes() throws {
        let serverAssisted = Data(hex: "0801" + "1011" + "1a04" + "6202" + "0801")
        let unknown = Data(hex: "0801" + "1011" + "1a04" + "6202" + "0809")

        #expect(try BindingReply.parse(serverAssisted).bindInfo?.verifyMode == .serverAssisted)
        #expect(try BindingReply.parse(unknown).bindInfo?.verifyMode == .unknown(9))
    }

    @Test("reads the band's public key, random and signature")
    func parsesDeviceVerify() throws {
        // Arrange
        let publicKey = Data(repeating: 0x04, count: 64)
        let random = Data(repeating: 0x05, count: 16)
        let signature = Data(repeating: 0x06, count: 32)
        let body = Data(hex: "0a40") + publicKey + Data(hex: "1210") + random + Data(hex: "1a20") + signature
        let reply = Data(hex: "0801" + "1012" + "1a79" + "920176") + body

        // Act
        let parsed = try BindingReply.parse(reply)

        // Assert
        #expect(parsed == .deviceVerify(publicKey: publicKey, random: random, signature: signature))
    }

    @Test("reads the confirmation result")
    func parsesConfirmResult() throws {
        let reply = Data(hex: "0801" + "1013" + "1a05" + "a20102" + "0801")

        #expect(try BindingReply.parse(reply) == .confirmResult(true))
    }

    @Test("reads an error code, such as 1 when the band is already bound")
    func parsesErrorCode() throws {
        let reply = Data(hex: "0801" + "1011" + "1a02" + "1801")

        #expect(try BindingReply.parse(reply) == .error(code: 1))
    }

    @Test("treats an account with no recognised field as success without detail")
    func parsesEmptyAccount() throws {
        let reply = Data(hex: "0801" + "1019")

        #expect(try BindingReply.parse(reply) == .acknowledged)
    }

    @Test("rejects a command that is not an account command")
    func rejectsOtherCommandTypes() {
        #expect(throws: BindingReplyError.unexpectedCommandType(8)) {
            try BindingReply.parse(Data(hex: "0808" + "1001"))
        }
    }

    @Test("rejects a device verify reply with a missing field")
    func rejectsIncompleteDeviceVerify() {
        let reply = Data(hex: "0801" + "1012" + "1a06" + "920103" + "0a0104")

        #expect(throws: BindingReplyError.missingField("deviceVerify")) {
            try BindingReply.parse(reply)
        }
    }

    @Test("rejects bytes that are not a protobuf message")
    func rejectsMalformedMessage() {
        #expect(throws: BindingReplyError.malformed(.truncated)) {
            try BindingReply.parse(Data(hex: "0801" + "1a05"))
        }
    }
}
