import SwiftUI

// Slider 0...1 that stops at the ceiling; the track above the ceiling is dimmed.
struct LevelSlider: View {
    let value: Double
    var ceiling: Double = 1
    let onChange: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let knobSize: CGFloat = 14
    private let trackHeight: CGFloat = 4
    private let step = 0.05

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - knobSize, 1)
            let knobOffset = travel * clamped(value)
            let ceilingX = knobSize / 2 + travel * clamped(ceiling)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: width, height: trackHeight)
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: ceiling < 1 ? ceilingX : width, height: trackHeight)
                Capsule()
                    .fill(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: knobSize / 2 + knobOffset, height: trackHeight)
                if ceiling < 1 {
                    Capsule()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: 10)
                        .offset(x: ceilingX - 1)
                }
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobOffset)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    guard isEnabled else { return }
                    onChange(min(clamped(Double((drag.location.x - knobSize / 2) / travel)), ceiling))
                }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + step, ceiling))
            case .decrement: onChange(max(value - step, 0))
            @unknown default: break
            }
        }
    }

    private func clamped(_ level: Double) -> Double {
        min(max(level, 0), 1)
    }
}
