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
    var recenterTrigger: Int = 0  // increment to snap back to the user
    let onAnnotationTap: (Data) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        // Muted, POI-free, always-dark cartography: friends are the only
        // saturated objects on the map, not cafes and dealerships
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        mapView.preferredConfiguration = config
        mapView.overrideUserInterfaceStyle = .dark
        mapView.showsCompass = false
        mapView.isRotateEnabled = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        // North-up situational awareness; heading-up belongs to TrackingView
        mapView.userTrackingMode = .follow
        mapView.register(BeaconAnnotationView.self, forAnnotationViewWithReuseIdentifier: "beacon")
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        updateAnnotations(mapView: mapView)

        if recenterTrigger != context.coordinator.lastRecenterTrigger {
            context.coordinator.lastRecenterTrigger = recenterTrigger
            context.coordinator.lastFitCoords = nil
            mapView.setUserTrackingMode(.follow, animated: true)
            return
        }

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
            mapView.userTrackingMode = .follow
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
        var lastRecenterTrigger = 0

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
            if annotation is MKUserLocation {
                // Own avatar instead of the default blue dot
                let identifier = "self-avatar"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = SelfAvatarRenderer.image()
                view.centerOffset = .zero
                return view
            }
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

/// Peer pin: identity-colored bubble with the peer's initial, transport shown
/// as a ring (green = direct BLE, purple = relay), and an always-visible
/// monospace name chip beneath — usernames on the map, not behind a tap.
class BeaconAnnotationView: MKAnnotationView {
    private static let bubbleSize: CGFloat = 32
    private let bubble = UILabel()
    private let nameChip = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        frame = CGRect(x: 0, y: 0, width: 88, height: 54)
        // Bubble center sits on the coordinate; the name hangs below
        centerOffset = CGPoint(x: 0, y: Self.bubbleSize / 2 - frame.height / 2)

        bubble.frame = CGRect(x: (frame.width - Self.bubbleSize) / 2, y: 0, width: Self.bubbleSize, height: Self.bubbleSize)
        bubble.textAlignment = .center
        bubble.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        bubble.textColor = .white
        bubble.layer.cornerRadius = Self.bubbleSize / 2
        bubble.layer.borderWidth = 2.5
        bubble.clipsToBounds = true
        addSubview(bubble)

        nameChip.frame = CGRect(x: 0, y: Self.bubbleSize + 4, width: frame.width, height: 16)
        nameChip.textAlignment = .center
        nameChip.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        nameChip.textColor = .white
        nameChip.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        nameChip.layer.cornerRadius = 8
        nameChip.clipsToBounds = true
        nameChip.lineBreakMode = .byTruncatingTail
        addSubview(nameChip)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with annotation: BeaconPointAnnotation) {
        let name = annotation.title ?? "?"
        bubble.text = String(name.prefix(1)).uppercased()
        bubble.backgroundColor = UIColor(BeaconProfile.peerColor(nickname: name))
        bubble.layer.borderColor = (annotation.transport == .ble ? UIColor.systemGreen : UIColor.systemPurple).cgColor
        nameChip.text = name
        // Chip hugs the text instead of filling the 88pt frame
        let textWidth = (name as NSString).size(withAttributes: [.font: nameChip.font!]).width + 16
        let chipWidth = min(textWidth, frame.width)
        nameChip.frame = CGRect(x: (frame.width - chipWidth) / 2, y: Self.bubbleSize + 4, width: chipWidth, height: 16)
    }
}

/// Renders the local user's avatar (emoji on their chosen color) for the map.
@MainActor
enum SelfAvatarRenderer {
    static func image() -> UIImage {
        let size: CGFloat = 36
        let profile = BeaconProfile.shared
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor(profile.avatarColor).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.white.setStroke()
            ctx.cgContext.setLineWidth(2.5)
            ctx.cgContext.strokeEllipse(in: CGRect(x: 1.25, y: 1.25, width: size - 2.5, height: size - 2.5))
            let emoji = profile.avatarEmoji as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
            let textSize = emoji.size(withAttributes: attrs)
            emoji.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attrs)
        }
    }
}
#endif
