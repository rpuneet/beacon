//
// CompassMapView.swift
// bitchat
//
// Simple MKMapView wrapper for beacon
//

import SwiftUI
import MapKit

// MARK: - Shared Types (available on all platforms)

struct BeaconAnnotation: Identifiable {
    let noiseKey: Data
    let nickname: String
    let coordinate: CLLocationCoordinate2D
    let transport: PeerLocation.TransportType
    var id: String { noiseKey.hexEncodedString() }
}

#if os(iOS)
import CoreLocation

struct CompassMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [BeaconAnnotation]
    let showsUserLocation: Bool
    let fitCoordinates: [CLLocationCoordinate2D]?  // Fit map to show these coordinates
    let onAnnotationTap: (Data) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.showsCompass = true
        mapView.isRotateEnabled = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        mapView.userTrackingMode = .followWithHeading
        mapView.register(BeaconAnnotationView.self, forAnnotationViewWithReuseIdentifier: "beacon")
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        updateAnnotations(mapView: mapView)

        // Fit to coordinates if provided, but only when the set materially
        // changed — refitting on every update would fight pan/zoom gestures
        if let coords = fitCoordinates, !coords.isEmpty {
            if context.coordinator.shouldRefit(for: coords) {
                mapView.userTrackingMode = .none
                let mapRect = coords.reduce(MKMapRect.null) { rect, coord in
                    let point = MKMapPoint(coord)
                    let pointRect = MKMapRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
                    return rect.union(pointRect)
                }
                let padding = UIEdgeInsets(top: 60, left: 40, bottom: 120, right: 40)
                mapView.setVisibleMapRect(mapRect, edgePadding: padding, animated: true)
                context.coordinator.lastFitCoords = coords
            }
        } else if context.coordinator.lastFitCoords != nil {
            // Switched back to no fit - return to user tracking
            context.coordinator.lastFitCoords = nil
            mapView.userTrackingMode = .followWithHeading
        }
    }

    private func updateAnnotations(mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? BeaconPointAnnotation }
        let existingIds = Set(existing.map { $0.noiseKeyHex })
        let newIds = Set(annotations.map { $0.noiseKey.hexEncodedString() })

        mapView.removeAnnotations(existing.filter { !newIds.contains($0.noiseKeyHex) })

        for ann in annotations where !existingIds.contains(ann.noiseKey.hexEncodedString()) {
            mapView.addAnnotation(BeaconPointAnnotation(annotation: ann))
        }

        for existing in existing {
            if let updated = annotations.first(where: { $0.noiseKey.hexEncodedString() == existing.noiseKeyHex }) {
                existing.coordinate = updated.coordinate
                existing.title = updated.nickname
                if let view = mapView.view(for: existing) as? BeaconAnnotationView {
                    view.configure(with: existing)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CompassMapView
        var lastFitCoords: [CLLocationCoordinate2D]?

        init(_ parent: CompassMapView) { self.parent = parent }

        /// Refit only when a coordinate was added/removed or moved > 50 m,
        /// so user pan/zoom isn't constantly overridden.
        func shouldRefit(for coords: [CLLocationCoordinate2D]) -> Bool {
            guard let last = lastFitCoords, last.count == coords.count else { return true }
            for (a, b) in zip(last, coords) {
                if MKMapPoint(a).distance(to: MKMapPoint(b)) > 50 { return true }
            }
            return false
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let beacon = annotation as? BeaconPointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "beacon", for: annotation) as! BeaconAnnotationView
            view.configure(with: beacon)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? BeaconPointAnnotation,
                  let key = Data(hexString: ann.noiseKeyHex) else { return }
            parent.onAnnotationTap(key)
            mapView.deselectAnnotation(ann, animated: false)
        }
    }
}

class BeaconPointAnnotation: MKPointAnnotation {
    let noiseKeyHex: String
    var transport: PeerLocation.TransportType

    init(annotation: BeaconAnnotation) {
        self.noiseKeyHex = annotation.noiseKey.hexEncodedString()
        self.transport = annotation.transport
        super.init()
        self.coordinate = annotation.coordinate
        self.title = annotation.nickname
    }
}

class BeaconAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.canShowCallout = false
        self.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with annotation: BeaconPointAnnotation) {
        let size: CGFloat = 32
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
        let ctx = UIGraphicsGetCurrentContext()!

        let color = annotation.transport == .ble ? UIColor.systemGreen : UIColor.systemPurple
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))

        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        if let icon = UIImage(systemName: "person.fill", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let iconSize = icon.size
            let iconRect = CGRect(x: (size - iconSize.width) / 2, y: (size - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            icon.draw(in: iconRect)
        }

        self.image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        self.centerOffset = CGPoint(x: 0, y: -size / 2)
    }
}
#endif
