//
// BeaconIcon.swift
// bitchat
//
// Custom beacon icon - "B" shape formed by pulse waves
//

import SwiftUI

struct BeaconIcon: View {
    let size: CGFloat
    var color: Color = .cyan

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let lineWidth = s * 0.08

            // Vertical spine of the "B" (left edge)
            let spinePath = Path { p in
                p.move(to: CGPoint(x: s * 0.25, y: s * 0.15))
                p.addLine(to: CGPoint(x: s * 0.25, y: s * 0.85))
            }
            context.stroke(spinePath, with: .color(color), lineWidth: lineWidth)

            // Top arc of "B" - smaller bump
            let topArc = Path { p in
                p.addArc(
                    center: CGPoint(x: s * 0.25, y: s * 0.35),
                    radius: s * 0.2,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }
            context.stroke(topArc, with: .color(color), lineWidth: lineWidth)

            // Bottom arc of "B" - larger bump
            let bottomArc = Path { p in
                p.addArc(
                    center: CGPoint(x: s * 0.25, y: s * 0.65),
                    radius: s * 0.25,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }
            context.stroke(bottomArc, with: .color(color), lineWidth: lineWidth)

            // Outer pulse waves (echoing the B shape)
            for i in 1...2 {
                let offset = CGFloat(i) * s * 0.12
                let opacity = 0.6 - Double(i) * 0.2

                // Top wave
                let topWave = Path { p in
                    p.addArc(
                        center: CGPoint(x: s * 0.25, y: s * 0.35),
                        radius: s * 0.2 + offset,
                        startAngle: .degrees(-60),
                        endAngle: .degrees(60),
                        clockwise: false
                    )
                }
                context.stroke(topWave, with: .color(color.opacity(opacity)), lineWidth: lineWidth * 0.6)

                // Bottom wave
                let bottomWave = Path { p in
                    p.addArc(
                        center: CGPoint(x: s * 0.25, y: s * 0.65),
                        radius: s * 0.25 + offset,
                        startAngle: .degrees(-50),
                        endAngle: .degrees(50),
                        clockwise: false
                    )
                }
                context.stroke(bottomWave, with: .color(color.opacity(opacity)), lineWidth: lineWidth * 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 20) {
        BeaconIcon(size: 16)
        BeaconIcon(size: 24, color: .green)
        BeaconIcon(size: 48, color: .cyan)
        BeaconIcon(size: 80, color: .orange)
    }
    .padding(40)
    .background(Color.black)
}
