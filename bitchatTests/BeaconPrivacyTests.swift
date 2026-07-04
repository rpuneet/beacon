//
//  BeaconPrivacyTests.swift
//  bitchatTests
//
//  Locks in the Beacon privacy guarantees: sharing policy gates,
//  precision coarsening, per-friend overrides, and audit logging.
//

import XCTest
@testable import bitchat

@MainActor
final class BeaconPrivacyTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "BeaconPrivacyTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var peerA: Data { Data(repeating: 0xAA, count: 32) }
    private var peerB: Data { Data(repeating: 0xBB, count: 32) }

    // MARK: - Policy Defaults

    func testDefaultsRequireMutualFavorites() {
        let settings = BeaconSettings(defaults: defaults)

        XCTAssertTrue(settings.isSharingEnabled)
        XCTAssertTrue(settings.requireMutualFavorites, "Mutual-only must be the default (docs promise it)")
        XCTAssertEqual(settings.precision, .exact)
    }

    func testNonFavoriteNeverReceivesLocation() {
        let settings = BeaconSettings(defaults: defaults)
        XCTAssertFalse(settings.canShare(with: peerA, isFavorite: false, isMutual: false))
    }

    func testOneSidedFavoriteDeniedByDefault() {
        let settings = BeaconSettings(defaults: defaults)
        XCTAssertFalse(settings.canShare(with: peerA, isFavorite: true, isMutual: false))
    }

    func testMutualFavoriteAllowedByDefault() {
        let settings = BeaconSettings(defaults: defaults)
        XCTAssertTrue(settings.canShare(with: peerA, isFavorite: true, isMutual: true))
    }

    func testOneSidedFavoriteAllowedWhenMutualNotRequired() {
        let settings = BeaconSettings(defaults: defaults)
        settings.requireMutualFavorites = false
        XCTAssertTrue(settings.canShare(with: peerA, isFavorite: true, isMutual: false))
    }

    func testGlobalKillSwitchOverridesEverything() {
        let settings = BeaconSettings(defaults: defaults)
        settings.isSharingEnabled = false
        XCTAssertFalse(settings.canShare(with: peerA, isFavorite: true, isMutual: true))
    }

    // MARK: - Per-Friend Overrides

    func testBlockedFriendIsDenied() {
        let settings = BeaconSettings(defaults: defaults)
        settings.setAllowed(false, for: peerA)

        XCTAssertFalse(settings.canShare(with: peerA, isFavorite: true, isMutual: true))
        XCTAssertTrue(settings.canShare(with: peerB, isFavorite: true, isMutual: true),
                      "Blocking one friend must not affect others")
    }

    func testPerFriendPrecisionOverridesGlobal() {
        let settings = BeaconSettings(defaults: defaults)
        settings.precision = .exact
        settings.setPrecision(.city, for: peerA)

        XCTAssertEqual(settings.effectivePrecision(for: peerA), .city)
        XCTAssertEqual(settings.effectivePrecision(for: peerB), .exact)
    }

    func testSettingsPersistAcrossInstances() {
        let settings = BeaconSettings(defaults: defaults)
        settings.isSharingEnabled = false
        settings.requireMutualFavorites = false
        settings.precision = .approximate
        settings.setAllowed(false, for: peerA)
        settings.setPrecision(.city, for: peerB)

        let reloaded = BeaconSettings(defaults: defaults)
        XCTAssertFalse(reloaded.isSharingEnabled)
        XCTAssertFalse(reloaded.requireMutualFavorites)
        XCTAssertEqual(reloaded.precision, .approximate)
        XCTAssertFalse(reloaded.override(for: peerA).isAllowed)
        XCTAssertEqual(reloaded.override(for: peerB).precision, .city)
    }

    // MARK: - Fail-Closed Behavior

    func testCorruptOverridesFailClosed() {
        defaults.set(Data("not json".utf8), forKey: "beacon.peerOverrides")

        let settings = BeaconSettings(defaults: defaults)
        XCTAssertFalse(settings.isSharingEnabled,
                       "Losing per-friend denies must disable sharing, not silently allow everyone")
        XCTAssertFalse(settings.canShare(with: peerA, isFavorite: true, isMutual: true))
    }

    func testUnrecognizedPrecisionFallsBackToCoarsest() {
        defaults.set("ultra-precise-future-level", forKey: "beacon.precision")

        let settings = BeaconSettings(defaults: defaults)
        XCTAssertEqual(settings.precision, .city,
                       "Unknown precision must resolve to the coarsest disclosure, never exact")
    }

    func testCorruptAuditLogDoesNotCrashAndStartsEmpty() {
        defaults.set(Data("garbage".utf8), forKey: "beacon.auditLog")

        let log = BeaconAuditLog(defaults: defaults)
        XCTAssertTrue(log.events.isEmpty)
        // Recording still works after a corrupt load
        log.record(.locationSent, peerFingerprint: "abc", peerName: "alice")
        XCTAssertEqual(log.events.count, 1)
    }

    // MARK: - Coarsening

    func testExactPrecisionIsPassthrough() {
        let result = BeaconSettings.coarsen(latitude: 37.774929, longitude: -122.419416,
                                            horizontalAccuracy: 5, to: .exact)
        XCTAssertEqual(result.latitude, 37.774929, accuracy: 1e-9)
        XCTAssertEqual(result.longitude, -122.419416, accuracy: 1e-9)
        XCTAssertEqual(result.horizontalAccuracy, 5, accuracy: 1e-9)
    }

    func testApproximateSnapsToGridCellCenter() {
        let result = BeaconSettings.coarsen(latitude: 37.774929, longitude: -122.419416,
                                            horizontalAccuracy: 5, to: .approximate)
        // 0.01° grid: 37.774929 → cell [37.77, 37.78) → center 37.775
        XCTAssertEqual(result.latitude, 37.775, accuracy: 1e-9)
        XCTAssertEqual(result.longitude, -122.415, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result.horizontalAccuracy, 1_100)
    }

    func testCitySnapsToCoarserGrid() {
        let result = BeaconSettings.coarsen(latitude: 37.774929, longitude: -122.419416,
                                            horizontalAccuracy: 5, to: .city)
        // 0.05° grid: 37.774929 → cell [37.75, 37.80) → center 37.775
        XCTAssertEqual(result.latitude, 37.775, accuracy: 1e-9)
        XCTAssertEqual(result.longitude, -122.425, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result.horizontalAccuracy, 5_500)
    }

    func testCoarseningNeverReturnsOriginalCoordinateUnlessOnCenter() {
        // Two nearby points in the same cell must coarsen identically
        let a = BeaconSettings.coarsen(latitude: 37.7712, longitude: -122.4145,
                                       horizontalAccuracy: 5, to: .approximate)
        let b = BeaconSettings.coarsen(latitude: 37.7789, longitude: -122.4111,
                                       horizontalAccuracy: 5, to: .approximate)
        XCTAssertEqual(a.latitude, b.latitude, accuracy: 1e-9)
        XCTAssertEqual(a.longitude, b.longitude, accuracy: 1e-9)
    }

    func testCoarseningWorksForNegativeCoordinates() {
        let result = BeaconSettings.coarsen(latitude: -33.868820, longitude: 151.209290,
                                            horizontalAccuracy: 5, to: .approximate)
        XCTAssertEqual(result.latitude, -33.865, accuracy: 1e-9)
        XCTAssertEqual(result.longitude, 151.205, accuracy: 1e-9)
    }

    // MARK: - Audit Log

    func testAuditRecordsAndPersists() {
        let log = BeaconAuditLog(defaults: defaults)
        log.record(.locationSent, peerFingerprint: "abc123", peerName: "alice", precision: "exact")
        log.record(.locationReceived, peerFingerprint: "def456", peerName: "bob")

        XCTAssertEqual(log.events.count, 2)

        let reloaded = BeaconAuditLog(defaults: defaults)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.events.first?.type, .locationSent)
        XCTAssertEqual(reloaded.events.first?.precision, "exact")
    }

    func testActiveSharingPeersDeduplicatesAndFilters() {
        let log = BeaconAuditLog(defaults: defaults)
        log.record(.locationSent, peerFingerprint: "abc123", peerName: "alice")
        log.record(.locationSent, peerFingerprint: "abc123", peerName: "alice")
        log.record(.locationReceived, peerFingerprint: "def456", peerName: "bob")

        let active = log.activeSharingPeers
        XCTAssertEqual(active.count, 1, "Received events and duplicates must not inflate the sharing list")
        XCTAssertEqual(active.first?.fingerprint, "abc123")
        XCTAssertTrue(log.isActivelySharing)
    }

    func testDeniedPingDoesNotCountAsSharing() {
        let log = BeaconAuditLog(defaults: defaults)
        log.record(.pingDenied, peerFingerprint: "abc123", peerName: "alice")

        XCTAssertFalse(log.isActivelySharing)
    }

    func testAuditLogCapsEventCount() {
        let log = BeaconAuditLog(defaults: defaults)
        for i in 0..<600 {
            log.record(.locationSent, peerFingerprint: "peer\(i)", peerName: "peer\(i)")
        }
        XCTAssertLessThanOrEqual(log.events.count, 500)
        // Oldest events dropped, newest kept
        XCTAssertEqual(log.events.last?.peerFingerprint, "peer599")
    }

    func testClearAllWipesStorage() {
        let log = BeaconAuditLog(defaults: defaults)
        log.record(.locationSent, peerFingerprint: "abc123", peerName: "alice")
        log.clearAll()

        XCTAssertTrue(log.events.isEmpty)
        let reloaded = BeaconAuditLog(defaults: defaults)
        XCTAssertTrue(reloaded.events.isEmpty)
    }
}
