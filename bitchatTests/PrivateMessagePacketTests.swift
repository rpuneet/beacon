//
//  PrivateMessagePacketTests.swift
//  bitchatTests
//
//  Locks in the TLV wire format: short content stays byte-identical with
//  upstream bitchat (1-byte length), content > 255 bytes uses the fork's
//  content16 extension so beacon UWB-token messages aren't dropped.
//

import XCTest
@testable import bitchat

final class PrivateMessagePacketTests: XCTestCase {

    func testShortContentRoundTrip() {
        let packet = PrivateMessagePacket(messageID: "ABC123", content: "[PING]:8CD15541:-72:37.774929,-122.419415,10,5,10")
        let encoded = packet.encode()
        XCTAssertNotNil(encoded)

        let decoded = PrivateMessagePacket.decode(from: encoded!)
        XCTAssertEqual(decoded?.messageID, packet.messageID)
        XCTAssertEqual(decoded?.content, packet.content)
    }

    func testShortContentUsesUpstreamCompatibleEncoding() {
        let packet = PrivateMessagePacket(messageID: "id", content: "hello")
        let encoded = packet.encode()!

        // messageID TLV: [0x00][len][bytes], then content TLV must be the
        // 1-byte-length type 0x01 for upstream compatibility
        let contentTypeOffset = 2 + 2  // type + len + "id"
        XCTAssertEqual(encoded[contentTypeOffset], 0x01)
        XCTAssertEqual(encoded[contentTypeOffset + 1], 5)
    }

    func testLongContentRoundTrip() {
        // Simulates a beacon PING carrying a UWB discovery token
        let token = String(repeating: "A", count: 400)
        let packet = PrivateMessagePacket(messageID: "REQ1", content: "[PING]:REQ1:-60:37.775,-122.419,10,5,10:\(token)")
        let encoded = packet.encode()
        XCTAssertNotNil(encoded, "Content > 255 bytes must encode (was silently dropped before content16)")

        let decoded = PrivateMessagePacket.decode(from: encoded!)
        XCTAssertEqual(decoded?.content, packet.content)
        XCTAssertEqual(decoded?.messageID, "REQ1")
    }

    func testLongContentUsesContent16Type() {
        let packet = PrivateMessagePacket(messageID: "id", content: String(repeating: "x", count: 300))
        let encoded = packet.encode()!

        let contentTypeOffset = 2 + 2
        XCTAssertEqual(encoded[contentTypeOffset], 0x02)
        let length = (Int(encoded[contentTypeOffset + 1]) << 8) | Int(encoded[contentTypeOffset + 2])
        XCTAssertEqual(length, 300)
    }

    func testOversizedContentFailsToEncode() {
        let packet = PrivateMessagePacket(messageID: "id", content: String(repeating: "x", count: 70_000))
        XCTAssertNil(packet.encode())
    }

    func testTruncatedContent16Rejected() {
        var data = Data([0x00, 2]) + Data("id".utf8)
        data.append(contentsOf: [0x02, 0x01, 0x00])  // claims 256 bytes
        data.append(Data("short".utf8))              // only 5 present
        XCTAssertNil(PrivateMessagePacket.decode(from: data))
    }
}
