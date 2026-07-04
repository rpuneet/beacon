//
//  DIVerificationTests.swift
//  bitchatTests
//
//  Verifies dependency injection works with real and mock providers.
//

import XCTest
import BitFoundation
@testable import bitchat

final class DIVerificationTests: XCTestCase {

    // MARK: - Mock Provider Tests

    func testMockBLEServiceCanBeCreated() throws {
        let bus = MockBLEBus()
        let mock = MockBLEService(bus: bus)

        XCTAssertNotNil(mock)
        XCTAssertEqual(mock.connectedPeers.count, 0)
    }

    func testMockBLEServiceTracksConnectedPeers() throws {
        let bus = MockBLEBus()
        let mock = MockBLEService(bus: bus)
        let peerID = PeerID(str: "TEST1234")

        mock.simulateConnectedPeer(peerID)

        XCTAssertTrue(mock.connectedPeers.contains(peerID))
        XCTAssertTrue(mock.isPeerConnected(peerID))
    }

    func testMockBLEServiceTracksDisconnectedPeers() throws {
        let bus = MockBLEBus()
        let mock = MockBLEService(bus: bus)
        let peerID = PeerID(str: "TEST1234")

        mock.simulateConnectedPeer(peerID)
        mock.simulateDisconnectedPeer(peerID)

        XCTAssertFalse(mock.connectedPeers.contains(peerID))
        XCTAssertFalse(mock.isPeerConnected(peerID))
    }

    func testMockKeychainCanBeCreated() throws {
        let mock = MockKeychain()
        XCTAssertNotNil(mock)
    }

    func testMockTransportCanBeCreated() throws {
        let mock = MockTransport()
        XCTAssertNotNil(mock)
    }

    func testMockIdentityManagerCanBeCreated() throws {
        let mockKeychain = MockKeychain()
        let mock = MockIdentityManager(mockKeychain)
        XCTAssertNotNil(mock)
    }

    // MARK: - Provider Interchangeability

    func testMockBLEBusCoordinatesMultipleServices() throws {
        let bus = MockBLEBus()

        let service1 = MockBLEService(
            peerID: PeerID(str: "PEER0001"),
            nickname: "Alice",
            bus: bus
        )
        let service2 = MockBLEService(
            peerID: PeerID(str: "PEER0002"),
            nickname: "Bob",
            bus: bus
        )

        // Simulate connection
        service1.simulateConnection(with: service2)

        XCTAssertTrue(service1.isPeerConnected(service2.peerID))
        XCTAssertTrue(service2.isPeerConnected(service1.peerID))
    }

    func testMockServicesCanSendMessages() throws {
        let bus = MockBLEBus()
        let service = MockBLEService(bus: bus)

        service.sendMessage("Test message")

        XCTAssertEqual(service.sentMessages.count, 1)
        XCTAssertEqual(service.sentMessages.first?.message.content, "Test message")
    }

    // MARK: - Noise Encryption Service DI

    func testNoiseServiceAcceptsMockKeychain() throws {
        let mockKeychain = MockKeychain()
        let noiseService = NoiseEncryptionService(keychain: mockKeychain)

        XCTAssertNotNil(noiseService)
    }

    // MARK: - Message Routing with Mocks

    func testMessageDeliveryBetweenMockServices() throws {
        let bus = MockBLEBus()

        let alice = MockBLEService(
            peerID: PeerID(str: "ALICE001"),
            nickname: "Alice",
            bus: bus
        )
        let bob = MockBLEService(
            peerID: PeerID(str: "BOB00001"),
            nickname: "Bob",
            bus: bus
        )

        var receivedMessage: BitchatMessage?
        bob.messageDeliveryHandler = { message in
            receivedMessage = message
        }

        alice.simulateConnection(with: bob)
        alice.sendMessage("Hello Bob!")

        // Give async delivery time
        let expectation = XCTestExpectation(description: "Message delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertNotNil(receivedMessage)
        XCTAssertEqual(receivedMessage?.content, "Hello Bob!")
    }
}
