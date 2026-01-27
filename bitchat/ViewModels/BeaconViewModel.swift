//
// BeaconViewModel.swift
// bitchat
//
// UI state management for the beacon feature
//

import Foundation
import MapKit
import SwiftUI
import Combine

/// ViewModel for beacon UI state management
@MainActor
final class BeaconViewModel: ObservableObject {
    // MARK: - Published State

    @Published var selectedPeerID: String?
    @Published var mapRegion: MKCoordinateRegion
    @Published var showingPeerDetail: Bool = false
    @Published var userHasInteracted: Bool = false

    // MARK: - Dependencies

    let beaconService: BeaconService
    let locationManager: LocationStateManager

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        beaconService: BeaconService = .shared,
        locationManager: LocationStateManager = .shared
    ) {
        self.beaconService = beaconService
        self.locationManager = locationManager

        // Center on user location or default
        if let loc = locationManager.currentLocation {
            self.mapRegion = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else {
            self.mapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        setupObservers()
    }

    // MARK: - Computed Properties

    /// Current user location
    var myLocation: CLLocationCoordinate2D? {
        locationManager.currentLocation?.coordinate
    }

    /// All peers with valid location data
    var peersWithLocation: [PeerLocation] {
        beaconService.peerLocations.values
            .filter { $0.hasLocation }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// All peer locations (including those without GPS)
    var allPeerLocations: [PeerLocation] {
        Array(beaconService.peerLocations.values)
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Selected peer location if any
    var selectedPeerLocation: PeerLocation? {
        guard let id = selectedPeerID else { return nil }
        return beaconService.peerLocations[id]
    }

    /// Title for the ping button based on state
    var pingButtonTitle: String {
        switch beaconService.pingState {
        case .idle:
            return "Ping Friends"
        case .pinging(let sent, let received):
            return "Pinging... (\(received)/\(sent))"
        case .completed(let received, let total):
            return "\(received)/\(total) responded"
        case .failed(let msg):
            return "Failed: \(msg)"
        }
    }

    /// Whether a ping is currently in progress
    var isPinging: Bool {
        beaconService.isPinging
    }

    /// Number of peers with location
    var peersWithLocationCount: Int {
        peersWithLocation.count
    }

    // MARK: - Actions

    /// Send ping to all mutual favorites
    func pingAll() {
        beaconService.pingAllFavorites()
    }

    /// Select a peer and show details
    func selectPeer(_ peerIDString: String) {
        selectedPeerID = peerIDString
        showingPeerDetail = true

        // Center map on peer
        if let location = beaconService.peerLocations[peerIDString]?.coordinate {
            mapRegion.center = location
        }
    }

    /// Deselect the currently selected peer
    func deselectPeer() {
        selectedPeerID = nil
        showingPeerDetail = false
    }

    /// Center the map on the user's location
    func centerOnUser() {
        if let loc = myLocation {
            mapRegion.center = loc
        }
    }

    /// Update map region to fit all peers
    func fitAllPeers() {
        guard !peersWithLocation.isEmpty else { return }

        // Include user location in the region calculation
        var coordinates = peersWithLocation.compactMap { $0.coordinate }
        if let myLoc = myLocation {
            coordinates.append(myLoc)
        }

        guard !coordinates.isEmpty else { return }

        // Calculate bounding box
        let minLat = coordinates.map { $0.latitude }.min() ?? 0
        let maxLat = coordinates.map { $0.latitude }.max() ?? 0
        let minLon = coordinates.map { $0.longitude }.min() ?? 0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latDelta = max(0.01, (maxLat - minLat) * 1.5)
        let lonDelta = max(0.01, (maxLon - minLon) * 1.5)

        mapRegion = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observe location changes to update UI
        beaconService.$peerLocations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        beaconService.$pingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
