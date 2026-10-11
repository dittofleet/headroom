import HeadroomCore
import SwiftUI

extension Level {
    var color: Color? {
        switch self {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// A usage bar: a rounded track, the fill, and the pace tick, as in the
/// Mac menu. `overlay` lays other limits over the fill, one horizontal
/// strip each, like the Mac's Stacked menu bar mode: drawn over the track
/// past the fill, and lightening the fill over it.
struct UsageBar: View {
    var percent: Double
    var pace: Double?
    var overlay: [Double] = []
    var tint: Color = .accentColor
    var dimmed = false
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let front = fillWidth(percent, width: width)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                ZStack(alignment: .leading) {
                    strips(width: width) { value in
                        Rectangle().foregroundStyle((Level(percent: value).color ?? .primary).opacity(dimmed ? 0.35 : 0.7))
                    }
                    Capsule()
                        .frame(width: front)
                        .foregroundStyle((Level(percent: percent).color ?? tint).opacity(dimmed ? 0.5 : 1))
                    strips(width: width) { _ in Rectangle() }
                        .mask(alignment: .leading) { Capsule().frame(width: front) }
                        .opacity(0.5)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .clipShape(Capsule())
            }
            .frame(width: width, height: height)
            // An overlay, so the tick, which is taller than the bar, can't
            // stretch the bar to its own height or move it off center.
            .overlay(alignment: .leading) {
                if let pace {
                    // Fill past the tick means usage is running ahead of the clock.
                    Rectangle()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 1.5, height: height + 3)
                        .offset(x: width * pace - 0.75)
                }
            }
        }
        .frame(height: height)
    }

    /// One strip per overlaid limit, each as long as that limit's fill.
    private func strips<Strip: View>(width: CGFloat, _ strip: @escaping (Double) -> Strip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(overlay.enumerated()), id: \.offset) { _, value in
                strip(value).frame(width: fillWidth(value, width: width))
            }
        }
    }

    /// Never shrinks below a visible nub once anything is used.
    private func fillWidth(_ value: Double, width: CGFloat) -> CGFloat {
        value > 0 ? max(width * value / 100, height) : 0
    }
}

/// One limit: label, percentage, bar, and optionally the reset time.
struct LimitRow: View {
    var limit: Limit
    var now: Date
    var dimmed: Bool
    var showPace: Bool
    var showReset = true
    var font: Font = .subheadline
    /// Thinner beside the widgets' smaller text.
    var barHeight: CGFloat = 5

    var body: some View {
        let percent = limit.percent(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.percent(percent))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Level(percent: percent).color ?? .primary))
            }
            .font(font)
            UsageBar(percent: percent, pace: showPace ? limit.elapsedFraction(at: now) : nil, dimmed: dimmed, height: barHeight)
            if showReset {
                Text(Format.reset(limit.resetsAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
