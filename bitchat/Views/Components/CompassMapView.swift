//
// CompassMapView.swift
// bitchat
//
// MKMapView wrapper with compass heading support for beacon
//

#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation

/// Map view that rotates based on device heading
struct CompassMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [BeaconAnnotation]
    let showsUserLocation: Bool
    let followsHeading: Bool
    let onAnnotationTap: (Data) -> Void
    let onMapInteraction: () -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.showsCompass = true
        mapView.isRotateEnabled = true

        // Enable heading tracking if requested
        if followsHeading {
            mapView.userTrackingMode = .followWithHeading
        }

        // Register annotation view
        mapView.register(BeaconAnnotationView.self, forAnnotationViewWithReuseIdentifier: BeaconAnnotationView.reuseIdentifier)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region if not following heading (user interaction)
        if !followsHeading {
            let currentCenter = mapView.region.center
            let newCenter = region.center
            let distance = CLLocation(latitude: currentCenter.latitude, longitude: currentCenter.longitude)
                .distance(from: CLLocation(latitude: newCenter.latitude, longitude: newCenter.longitude))

            // Only update if significantly different to avoid jitter
            if distance > 10 {
                mapView.setRegion(region, animated: true)
            }
        }

        // Update tracking mode
        if followsHeading && mapView.userTrackingMode != .followWithHeading {
            mapView.userTrackingMode = .followWithHeading
        } else if !followsHeading && mapView.userTrackingMode == .followWithHeading {
            mapView.userTrackingMode = .follow
        }

        // Update annotations
        updateAnnotations(mapView: mapView, context: context)
    }

    private func updateAnnotations(mapView: MKMapView, context: Context) {
        // Get existing annotations (excluding user location)
        let existingAnnotations = mapView.annotations.compactMap { $0 as? BeaconPointAnnotation }
        let existingIds = Set(existingAnnotations.map { $0.noiseKeyHex })
        let newIds = Set(annotations.map { $0.noiseKey.hexEncodedString() })

        // Remove old annotations
        let toRemove = existingAnnotations.filter { !newIds.contains($0.noiseKeyHex) }
        mapView.removeAnnotations(toRemove)

        // Add new annotations
        let toAdd = annotations.filter { !existingIds.contains($0.noiseKey.hexEncodedString()) }
        for annotation in toAdd {
            let pointAnnotation = BeaconPointAnnotation(annotation: annotation)
            mapView.addAnnotation(pointAnnotation)
        }

        // Update existing annotations
        for existing in existingAnnotations {
            if let updated = annotations.first(where: { $0.noiseKey.hexEncodedString() == existing.noiseKeyHex }) {
                existing.coordinate = updated.coordinate
                existing.title = updated.nickname
                existing.isSelected = updated.isSelected
                existing.hasUWB = updated.hasUWB
                existing.transport = updated.transport
                existing.isPongWave = updated.isPongWave

                // Refresh view
                if let view = mapView.view(for: existing) as? BeaconAnnotationView {
                    view.configure(with: existing)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CompassMapView

        init(_ parent: CompassMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.region = mapView.region
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let beaconAnnotation = annotation as? BeaconPointAnnotation else { return nil }

            let view = mapView.dequeueReusableAnnotationView(withIdentifier: BeaconAnnotationView.reuseIdentifier, for: annotation) as! BeaconAnnotationView
            view.configure(with: beaconAnnotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? BeaconPointAnnotation else { return }
            if let noiseKey = Data(hexString: annotation.noiseKeyHex) {
                parent.onAnnotationTap(noiseKey)
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            parent.onMapInteraction()
        }
    }
}

// MARK: - Supporting Types

struct BeaconAnnotation: Identifiable {
    let noiseKey: Data
    let nickname: String
    let coordinate: CLLocationCoordinate2D
    let isSelected: Bool
    let hasUWB: Bool
    let transport: PeerLocation.TransportType
    let isPongWave: Bool

    var id: String { noiseKey.hexEncodedString() }
}

class BeaconPointAnnotation: MKPointAnnotation {
    let noiseKeyHex: String
    var isSelected: Bool
    var hasUWB: Bool
    var transport: PeerLocation.TransportType
    var isPongWave: Bool

    init(annotation: BeaconAnnotation) {
        self.noiseKeyHex = annotation.noiseKey.hexEncodedString()
        self.isSelected = annotation.isSelected
        self.hasUWB = annotation.hasUWB
        self.transport = annotation.transport
        self.isPongWave = annotation.isPongWave
        super.init()
        self.coordinate = annotation.coordinate
        self.title = annotation.nickname
    }
}

class BeaconAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "BeaconAnnotationView"

    private var hostingController: UIHostingController<BeaconMapPin>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.canShowCallout = false
        self.frame = CGRect(x: 0, y: 0, width: 50, height: 60)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: BeaconPointAnnotation) {
        // Remove old hosting controller
        hostingController?.view.removeFromSuperview()

        // Create SwiftUI view
        let pinView = BeaconMapPin(
            nickname: annotation.title ?? "",
            isSelected: annotation.isSelected,
            hasUWB: annotation.hasUWB,
            transport: annotation.transport
        )

        let controller = UIHostingController(rootView: pinView)
        controller.view.backgroundColor = .clear
        controller.view.frame = self.bounds
        self.addSubview(controller.view)
        self.hostingController = controller

        // Adjust anchor
        self.centerOffset = CGPoint(x: 0, y: -self.frame.height / 2)
    }
}
#endif
