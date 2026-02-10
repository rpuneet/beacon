//
// TrackingMapView.swift
// bitchat
//
// Map view showing positions of both users with accuracy circles
//

import SwiftUI
import MapKit

/// Connection quality based on RSSI signal strength and online status
enum ConnectionQuality {
    case excellent  // > -50 dBm
    case good       // > -70 dBm
    case fair       // > -85 dBm
    case weak       // <= -85 dBm
    case connected  // Online but no RSSI data (relay or waiting for first response)
    case offline    // No signal

    init(rssi: Int?, isOnline: Bool = false) {
        guard let rssi = rssi else {
            // No RSSI data - show connected if online, otherwise offline
            self = isOnline ? .connected : .offline
            return
        }
        if rssi > -50 { self = .excellent }
        else if rssi > -70 { self = .good }
        else if rssi > -85 { self = .fair }
        else { self = .weak }
    }

    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .yellow
        case .fair: return .orange
        case .weak: return .red
        case .connected: return .green
        case .offline: return .gray
        }
    }

    var description: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .weak: return "Weak"
        case .connected: return "Connected"
        case .offline: return "Offline"
        }
    }
}

#if os(iOS)
import UIKit

struct TrackingMapView: UIViewRepresentable {
    let myLocation: CLLocationCoordinate2D?
    let myAccuracy: Double?
    let peerLocation: CLLocationCoordinate2D?
    let peerAccuracy: Double?
    let connectionQuality: ConnectionQuality
    let peerNickname: String

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.mapType = .standard
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true

        // Add gesture recognizers to detect user interaction
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidInteract))
        panGesture.delegate = context.coordinator
        mapView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userDidInteract))
        pinchGesture.delegate = context.coordinator
        mapView.addGestureRecognizer(pinchGesture)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Remove existing overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        var annotations: [MKAnnotation] = []
        var overlays: [MKOverlay] = []

        // My position
        if let myLoc = myLocation {
            let myAnnotation = TrackingAnnotation(
                coordinate: myLoc,
                title: "Me",
                isMe: true,
                connectionQuality: .excellent
            )
            annotations.append(myAnnotation)

            // Accuracy circle for me
            if let accuracy = myAccuracy, accuracy > 0 {
                let circle = TrackingCircle(center: myLoc, radius: accuracy)
                circle.isMe = true
                overlays.append(circle)
            }
        }

        // Peer position
        if let peerLoc = peerLocation {
            let peerAnnotation = TrackingAnnotation(
                coordinate: peerLoc,
                title: peerNickname,
                isMe: false,
                connectionQuality: connectionQuality
            )
            annotations.append(peerAnnotation)

            // Accuracy circle for peer
            if let accuracy = peerAccuracy, accuracy > 0 {
                let circle = TrackingCircle(center: peerLoc, radius: accuracy)
                circle.isMe = false
                circle.quality = connectionQuality
                overlays.append(circle)
            }
        }

        mapView.addOverlays(overlays)
        mapView.addAnnotations(annotations)

        // Only auto-fit region if user hasn't interacted with the map
        if !context.coordinator.userHasInteracted {
            updateMapRegion(mapView, animated: context.coordinator.hasSetInitialRegion)
            context.coordinator.hasSetInitialRegion = true
        }
    }

    private func updateMapRegion(_ mapView: MKMapView, animated: Bool) {
        guard let myLoc = myLocation else {
            if let peerLoc = peerLocation {
                let region = MKCoordinateRegion(
                    center: peerLoc,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                )
                mapView.setRegion(region, animated: animated)
            }
            return
        }

        guard let peerLoc = peerLocation else {
            let region = MKCoordinateRegion(
                center: myLoc,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            )
            mapView.setRegion(region, animated: animated)
            return
        }

        // Calculate region that fits both points with padding
        let minLat = min(myLoc.latitude, peerLoc.latitude)
        let maxLat = max(myLoc.latitude, peerLoc.latitude)
        let minLon = min(myLoc.longitude, peerLoc.longitude)
        let maxLon = max(myLoc.longitude, peerLoc.longitude)

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Calculate span with 50% padding, minimum of 0.005 degrees
        let latDelta = max((maxLat - minLat) * 1.5, 0.005)
        let lonDelta = max((maxLon - minLon) * 1.5, 0.005)

        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        mapView.setRegion(region, animated: animated)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: TrackingMapView
        var userHasInteracted = false
        var hasSetInitialRegion = false

        init(_ parent: TrackingMapView) {
            self.parent = parent
        }

        @objc func userDidInteract(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                userHasInteracted = true
            }
        }

        // Allow gesture recognizers to work simultaneously with map's built-in gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let trackingAnnotation = annotation as? TrackingAnnotation else { return nil }

            let identifier = trackingAnnotation.isMe ? "me" : "peer"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            } else {
                annotationView?.annotation = annotation
            }

            // Create dot image
            let size: CGFloat = 24
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            let image = renderer.image { ctx in
                let rect = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)

                // Fill color
                let fillColor: UIColor
                if trackingAnnotation.isMe {
                    fillColor = .systemBlue
                } else {
                    fillColor = UIColor(parent.connectionQuality.color)
                }

                fillColor.setFill()
                ctx.cgContext.fillEllipse(in: rect)

                // White border
                UIColor.white.setStroke()
                ctx.cgContext.setLineWidth(2)
                ctx.cgContext.strokeEllipse(in: rect)
            }

            annotationView?.image = image
            annotationView?.canShowCallout = true

            return annotationView
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? TrackingCircle {
                let renderer = MKCircleRenderer(circle: circle)

                let color: UIColor
                if circle.isMe {
                    color = .systemBlue
                } else {
                    color = UIColor(circle.quality.color)
                }

                renderer.fillColor = color.withAlphaComponent(0.15)
                renderer.strokeColor = color.withAlphaComponent(0.5)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

#elseif os(macOS)
import AppKit

struct TrackingMapView: NSViewRepresentable {
    let myLocation: CLLocationCoordinate2D?
    let myAccuracy: Double?
    let peerLocation: CLLocationCoordinate2D?
    let peerAccuracy: Double?
    let connectionQuality: ConnectionQuality
    let peerNickname: String

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.mapType = .standard
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        // Remove existing overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        var annotations: [MKAnnotation] = []
        var overlays: [MKOverlay] = []

        // My position
        if let myLoc = myLocation {
            let myAnnotation = TrackingAnnotation(
                coordinate: myLoc,
                title: "Me",
                isMe: true,
                connectionQuality: .excellent
            )
            annotations.append(myAnnotation)

            // Accuracy circle for me
            if let accuracy = myAccuracy, accuracy > 0 {
                let circle = TrackingCircle(center: myLoc, radius: accuracy)
                circle.isMe = true
                overlays.append(circle)
            }
        }

        // Peer position
        if let peerLoc = peerLocation {
            let peerAnnotation = TrackingAnnotation(
                coordinate: peerLoc,
                title: peerNickname,
                isMe: false,
                connectionQuality: connectionQuality
            )
            annotations.append(peerAnnotation)

            // Accuracy circle for peer
            if let accuracy = peerAccuracy, accuracy > 0 {
                let circle = TrackingCircle(center: peerLoc, radius: accuracy)
                circle.isMe = false
                circle.quality = connectionQuality
                overlays.append(circle)
            }
        }

        mapView.addOverlays(overlays)
        mapView.addAnnotations(annotations)

        // Only auto-fit region if user hasn't interacted with the map
        if !context.coordinator.userHasInteracted {
            updateMapRegion(mapView, animated: context.coordinator.hasSetInitialRegion)
            context.coordinator.hasSetInitialRegion = true
        }
    }

    private func updateMapRegion(_ mapView: MKMapView, animated: Bool) {
        guard let myLoc = myLocation else {
            if let peerLoc = peerLocation {
                let region = MKCoordinateRegion(
                    center: peerLoc,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                )
                mapView.setRegion(region, animated: animated)
            }
            return
        }

        guard let peerLoc = peerLocation else {
            let region = MKCoordinateRegion(
                center: myLoc,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            )
            mapView.setRegion(region, animated: animated)
            return
        }

        // Calculate region that fits both points with padding
        let minLat = min(myLoc.latitude, peerLoc.latitude)
        let maxLat = max(myLoc.latitude, peerLoc.latitude)
        let minLon = min(myLoc.longitude, peerLoc.longitude)
        let maxLon = max(myLoc.longitude, peerLoc.longitude)

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Calculate span with 50% padding, minimum of 0.005 degrees
        let latDelta = max((maxLat - minLat) * 1.5, 0.005)
        let lonDelta = max((maxLon - minLon) * 1.5, 0.005)

        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        mapView.setRegion(region, animated: animated)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackingMapView
        var userHasInteracted = false
        var hasSetInitialRegion = false

        init(_ parent: TrackingMapView) {
            self.parent = parent
        }

        // Detect user interaction via regionWillChangeAnimated
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // If region change wasn't initiated by our code (hasSetInitialRegion), mark as user interaction
            if hasSetInitialRegion {
                userHasInteracted = true
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let trackingAnnotation = annotation as? TrackingAnnotation else { return nil }

            let identifier = trackingAnnotation.isMe ? "me" : "peer"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            } else {
                annotationView?.annotation = annotation
            }

            // Create dot image
            let size: CGFloat = 24
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let drawRect = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)

                // Fill color
                let fillColor: NSColor
                if trackingAnnotation.isMe {
                    fillColor = .systemBlue
                } else {
                    fillColor = NSColor(self.parent.connectionQuality.color)
                }

                fillColor.setFill()
                let path = NSBezierPath(ovalIn: drawRect)
                path.fill()

                // White border
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.stroke()

                return true
            }

            annotationView?.image = image
            annotationView?.canShowCallout = true

            return annotationView
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? TrackingCircle {
                let renderer = MKCircleRenderer(circle: circle)

                let color: NSColor
                if circle.isMe {
                    color = .systemBlue
                } else {
                    color = NSColor(circle.quality.color)
                }

                renderer.fillColor = color.withAlphaComponent(0.15)
                renderer.strokeColor = color.withAlphaComponent(0.5)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
#endif

// MARK: - Custom Annotation

class TrackingAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let isMe: Bool
    let connectionQuality: ConnectionQuality

    init(coordinate: CLLocationCoordinate2D, title: String, isMe: Bool, connectionQuality: ConnectionQuality) {
        self.coordinate = coordinate
        self.title = title
        self.isMe = isMe
        self.connectionQuality = connectionQuality
    }
}

// MARK: - Custom Circle Overlay

class TrackingCircle: MKCircle {
    var isMe: Bool = false
    var quality: ConnectionQuality = .offline
}
