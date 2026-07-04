//
//  BeaconWireTests.swift
//  bitchatTests
//
//  Locks in the beacon PING/PONG wire format: parsing, encoding,
//  optional UWB token field, and malformed-input handling.
//

import XCTest
@testable import bitchat

@MainActor
final class BeaconWireTests: XCTestCase {

    // MARK: - Parsing

    func testParsesFullPing() {
        let msg = BeaconWire.parse("[PING]:8CD15541:-72:37.774929,-122.419415,10,5,10")
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.kind, .ping)
        XCTAssertEqual(msg?.requestID, "8CD15541")
        XCTAssertEqual(msg?.rssi, -72)
        XCTAssertEqual(msg?.location, BeaconWire.Location(lat: 37.774929, lon: -122.419415, alt: 10, hacc: 5, vacc: 10))
        XCTAssertNil(msg?.uwbToken)
        XCTAssertFalse(msg?.hasMalformedToken ?? true)
    }

    func testParsesPongWithoutLocationOrRSSI() {
        let msg = BeaconWire.parse("[PONG]:8CD15541::")
        XCTAssertEqual(msg?.kind, .pong)
        XCTAssertEqual(msg?.requestID, "8CD15541")
        XCTAssertNil(msg?.rssi)
        XCTAssertNil(msg?.location)
    }

    func testParsesUWBTokenField() {
        let token = Data([0x01, 0x02, 0x03, 0xFF])
        let msg = BeaconWire.parse("[PING]:REQ1:-60:1.5,2.5,0,5,-1:\(token.base64EncodedString())")
        XCTAssertEqual(msg?.uwbToken, token)
        XCTAssertFalse(msg?.hasMalformedToken ?? true)
    }

    func testMalformedTokenFlaggedButMessageStillParses() {
        let msg = BeaconWire.parse("[PING]:REQ1:-60:1.5,2.5,0,5,-1:!!!not-base64!!!")
        XCTAssertNotNil(msg, "A bad token must not invalidate the whole message")
        XCTAssertNil(msg?.uwbToken)
        XCTAssertTrue(msg?.hasMalformedToken ?? false)
        XCTAssertNotNil(msg?.location, "Location must survive a malformed trailing token")
    }

    func testTokenlessMessageParsesLikeOldClients() {
        // Backward compatibility: the pre-UWB format has no 4th field
        let msg = BeaconWire.parse("[PING]:REQ1:-60:1.5,2.5,0,5,10")
        XCTAssertNil(msg?.uwbToken)
        XCTAssertFalse(msg?.hasMalformedToken ?? true)
    }

    func testRejectsNonBeaconContent() {
        XCTAssertNil(BeaconWire.parse("hello there"))
        XCTAssertNil(BeaconWire.parse("[FAVORITED]:something"))
    }

    func testRejectsEmptyRequestID() {
        XCTAssertNil(BeaconWire.parse("[PING]::-60:1.5,2.5,0,5,10"))
    }

    func testMalformedLocationDropsLocationOnly() {
        XCTAssertNil(BeaconWire.parse("[PING]:REQ1:-60:garbage")?.location)
        XCTAssertNil(BeaconWire.parse("[PING]:REQ1:-60:1.0,2.0,3")?.location, "Wrong field count must not parse")
        XCTAssertEqual(BeaconWire.parse("[PING]:REQ1:-60:garbage")?.requestID, "REQ1")
    }

    // MARK: - Encoding

    func testEncodeParseRoundTrip() {
        let location = BeaconWire.Location(lat: -33.868820, lon: 151.209290, alt: 25, hacc: 8, vacc: 4)
        let content = BeaconWire.encode(kind: .pong, requestID: "AB12CD34", rssi: -55,
                                        locationStr: BeaconWire.encodeLocation(location))

        let parsed = BeaconWire.parse(content)
        XCTAssertEqual(parsed?.kind, .pong)
        XCTAssertEqual(parsed?.requestID, "AB12CD34")
        XCTAssertEqual(parsed?.rssi, -55)
        XCTAssertEqual(parsed?.location, location)
    }

    func testEncodeWithTokenRoundTrip() {
        let token = Data(repeating: 0xAB, count: 120)
        let content = BeaconWire.encode(kind: .ping, requestID: "REQ9", rssi: nil,
                                        locationStr: "", uwbTokenBase64: token.base64EncodedString())

        let parsed = BeaconWire.parse(content)
        XCTAssertEqual(parsed?.requestID, "REQ9")
        XCTAssertNil(parsed?.rssi)
        XCTAssertNil(parsed?.location)
        XCTAssertEqual(parsed?.uwbToken, token)
    }

    func testCoarsenedEncodingNeverLeaksExactCoordinate() {
        // End-to-end: coarsen then encode then parse — the exact input
        // coordinate must not survive the trip
        let coarse = BeaconSettings.coarsen(latitude: 37.774929, longitude: -122.419415,
                                            horizontalAccuracy: 5, to: .approximate)
        let encoded = BeaconWire.encodeLocation(BeaconWire.Location(
            lat: coarse.latitude, lon: coarse.longitude, alt: 0,
            hacc: Int(coarse.horizontalAccuracy), vacc: -1))

        let parsed = BeaconWire.decodeLocation(encoded)
        XCTAssertNotNil(parsed)
        XCTAssertNotEqual(parsed?.lat, 37.774929)
        XCTAssertNotEqual(parsed?.lon, -122.419415)
        XCTAssertGreaterThanOrEqual(parsed?.hacc ?? 0, 1_100)
    }
}
