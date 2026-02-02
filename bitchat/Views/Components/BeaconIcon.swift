//
// BeaconIcon.swift
// bitchat
//
// WiFi-style icon that forms a "b" shape
//

import SwiftUI

struct BeaconIcon: View {
    let size: CGFloat
    var color: Color = .cyan

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let strokeWidth = max(1.5, s * 0.1)

            // Vertical stem of "b" (left side)
            let stem = Path { p in
                p.move(to: CGPoint(x: s * 0.3, y: s * 0.1))
                p.addLine(to: CGPoint(x: s * 0.3, y: s * 0.75))
            }
            context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

            // WiFi-style arcs forming the "b" bump
            let arcCenter = CGPoint(x: s * 0.3, y: s * 0.6)
            let arcs: [(radius: CGFloat, opacity: Double)] = [
                (s * 0.18, 1.0),
                (s * 0.32, 0.7),
                (s * 0.46, 0.4)
            ]

            for arc in arcs {
                let path = Path { p in
                    p.addArc(
                        center: arcCenter,
                        radius: arc.radius,
                        startAngle: .degrees(-70),
                        endAngle: .degrees(70),
                        clockwise: false
                    )
                }
                context.stroke(
                    path,
                    with: .color(color.opacity(arc.opacity)),
                    style: StrokeStyle(lineWidth: strokeWidth * 0.8, lineCap: .round)
                )
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 20) {
        BeaconIcon(size: 14)
        BeaconIcon(size: 20, color: .green)
        BeaconIcon(size: 32, color: .cyan)
        BeaconIcon(size: 48, color: .orange)
    }
    .padding(30)
    .background(Color.black)
}
