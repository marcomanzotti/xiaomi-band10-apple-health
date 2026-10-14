import Foundation
import Testing
@testable import Band10Kit

// Byte sequences follow the protobuf wire-format specification; the first three
// are the worked examples from the official encoding guide.

@Suite("Protobuf encoding")
struct ProtobufEncodingTests {
    @Test("encodes a varint field")
    func encodesVarint() {
        #expect(Protobuf.varint(1, 150) == Data(hex: "089601"))
    }

    @Test("encodes a string field")
    func encodesString() {
        #expect(Protobuf.string(2, "testing") == Data(hex: "120774657374696e67"))
    }

    @Test("encodes an embedded message as a length-delimited field")
    func encodesEmbeddedMessage() {
        #expect(Protobuf.bytes(3, Protobuf.varint(1, 150)) == Data(hex: "1a03089601"))
    }

    @Test("encodes a field number above fifteen with a two-byte tag")
    func encodesLargeFieldNumber() {
        #expect(Protobuf.bytes(30, Data(hex: "aa")) == Data(hex: "f20101aa"))
    }

    @Test("encodes booleans as zero or one")
    func encodesBool() {
        #expect(Protobuf.bool(1, true) == Data(hex: "0801"))
        #expect(Protobuf.bool(1, false) == Data(hex: "0800"))
    }

    @Test("encodes a float as four little-endian bytes")
    func encodesFloat() {
        #expect(Protobuf.float(2, 1.0) == Data(hex: "150000803f"))
    }

    @Test("encodes the largest unsigned value in ten bytes")
    func encodesMaxVarint() {
        #expect(Protobuf.varint(1, UInt64.max) == Data(hex: "08ffffffffffffffffff01"))
    }
}

@Suite("Protobuf decoding")
struct ProtobufDecodingTests {
    @Test("decodes fields in order with their wire values")
    func decodesFields() throws {
        // Arrange: varint 1 = 150, string 2 = "hi", fixed32 3, bytes 30.
        let message = Data(hex: "089601" + "12026869" + "1d0000803f" + "f20101aa")

        // Act
        let fields = try Protobuf.decode(message)

        // Assert
        #expect(fields == [
            Protobuf.Field(number: 1, value: .varint(150)),
            Protobuf.Field(number: 2, value: .bytes(Data("hi".utf8))),
            Protobuf.Field(number: 3, value: .fixed32(0x3F80_0000)),
            Protobuf.Field(number: 30, value: .bytes(Data(hex: "aa"))),
        ])
    }

    @Test("decodes a fixed64 field")
    func decodesFixed64() throws {
        let fields = try Protobuf.decode(Data(hex: "090102030405060708"))

        #expect(fields == [Protobuf.Field(number: 1, value: .fixed64(0x0807_0605_0403_0201))])
    }

    @Test("decodes an empty message as no fields")
    func decodesEmptyMessage() throws {
        #expect(try Protobuf.decode(Data()).isEmpty)
    }

    @Test("decodes from a slice that does not start at index zero")
    func decodesSlice() throws {
        let padded = Data(hex: "ffff089601")

        #expect(try Protobuf.decode(padded.dropFirst(2)) == [Protobuf.Field(number: 1, value: .varint(150))])
    }

    @Test("round-trips what the encoder produces")
    func roundTrips() throws {
        let encoded = Protobuf.varint(1, 1) + Protobuf.varint(2, 26) + Protobuf.bytes(3, Protobuf.string(7, "user"))

        let fields = try Protobuf.decode(encoded)

        #expect(fields.map(\.number) == [1, 2, 3])
        #expect(fields[2].value == .bytes(Data(hex: "3a0475736572")))
    }

    @Test("throws when a length-delimited field runs past the end", arguments: ["1205686900", "12"])
    func rejectsTruncatedBytes(hex: String) {
        #expect(throws: ProtobufError.truncated) {
            try Protobuf.decode(Data(hex: hex))
        }
    }

    @Test("throws when a varint never terminates")
    func rejectsUnterminatedVarint() {
        #expect(throws: ProtobufError.truncated) {
            try Protobuf.decode(Data(hex: "08ffff"))
        }
    }

    @Test("throws when a varint is longer than ten bytes")
    func rejectsOverlongVarint() {
        #expect(throws: ProtobufError.malformedVarint) {
            try Protobuf.decode(Data(hex: "08ffffffffffffffffffff01"))
        }
    }

    @Test("throws on a wire type the band never uses")
    func rejectsUnsupportedWireType() {
        #expect(throws: ProtobufError.unsupportedWireType(3)) {
            try Protobuf.decode(Data(hex: "0b"))
        }
    }

    @Test("throws when a fixed-width field is cut short")
    func rejectsTruncatedFixed() {
        #expect(throws: ProtobufError.truncated) {
            try Protobuf.decode(Data(hex: "1d0000"))
        }
    }
}

@Suite("Protobuf field lookup")
struct ProtobufFieldLookupTests {
    private let fields = [
        Protobuf.Field(number: 1, value: .varint(7)),
        Protobuf.Field(number: 2, value: .bytes(Data("abc".utf8))),
        Protobuf.Field(number: 1, value: .varint(9)),
    ]

    @Test("returns the last occurrence of a repeated scalar, as protobuf requires")
    func lastValueWins() {
        #expect(fields.varint(1) == 9)
    }

    @Test("returns bytes and strings by field number")
    func readsBytesAndStrings() {
        #expect(fields.bytes(2) == Data("abc".utf8))
        #expect(fields.string(2) == "abc")
    }

    @Test("returns nil for an absent field or a different wire type")
    func missingOrMismatched() {
        #expect(fields.varint(5) == nil)
        #expect(fields.bytes(1) == nil)
        #expect(fields.varint(2) == nil)
    }
}
