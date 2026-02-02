//
// BeaconViewModel.swift
// bitchat
//
// UI state management for the beacon feature (legacy - kept for compatibility)
//

import Foundation
import MapKit
import Combine

/// ViewModel for beacon UI state (simplified - most logic now in BeaconService)
@MainActor
final class BeaconViewModel: ObservableObject {
    @Published var mapRegion: MKCoordinateRegion
    @Published var userHasInteracted: Bool = false
    @Published var followsHeading: Bool = true

    let beaconService: BeaconService
    let locationManager: LocationStateManager
    let favoritesService: FavoritesPersistenceService

    private var cancellables = Set<AnyCancellable>()

    init(
        beaconService: BeaconService = .shared,
        locationManager: LocationStateManager = .shared,
        favoritesService: FavoritesPersistenceService = .shared
    ) {
        self.beaconService = beaconService
        self.locationManager = locationManager
        self.favoritesService = favoritesService

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

    var isBeaconModeEnabled: Bool {
        get { beaconService.isBeaconModeEnabled }
        set { beaconService.isBeaconModeEnabled = newValue }
    }

    var isPinging: Bool { beaconService.isPinging }
    var peersWithLocationCount: Int { beaconService.peersWithLocationCount }
    var favoritesCount: Int { favoritesService.favorites.values.filter { $0.isFavorite }.count }

    func toggleBeaconMode() { isBeaconModeEnabled.toggle() }
    func stopBeaconMode() { isBeaconModeEnabled = false }
    func pingAll() { beaconService.pingAllFavorites() }

    private func setupObservers() {
        beaconService.$peerLocations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        beaconService.$isPinging
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
