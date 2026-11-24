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
/// Mac menu. `percent` is the share used, filled as what is left when
/// `remaining`, and nil leaves the track empty.
struct UsageBar: View {
    var percent: Double?
    var remaining: Bool
    var pace: Double?
    var tint: Color = .accentColor
    var dimmed = false
    var height: CGFloat = 5
    /// For a model's own weekly, like Fable's.
    var dotted = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                // Never shrinks below a visible nub while there is any.
                let shown = Format.fill(percent, remaining: remaining)
                let fillWidth = shown > 0 ? max(width * shown / 100, height) : 0
                let fillColor = (Level(percent: percent ?? 0).color ?? tint).opacity(dimmed ? 0.5 : 1)
                if dotted {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height / 2))
                        path.addLine(to: CGPoint(x: fillWidth, y: height / 2))
                    }
                    .stroke(fillColor, style: StrokeStyle(lineWidth: height, dash: [2, 1]))
                } else {
                    Capsule().frame(width: fillWidth).foregroundStyle(fillColor)
                }
            }
            .frame(width: width, height: height)
            // An overlay, so the tick, which is taller than the bar, can't
            // stretch the bar to its own height or move it off center.
            .overlay(alignment: .leading) {
                if let pace {
                    // Fill past the tick, or short of it when counting down,
                    // means usage is running ahead of the clock.
                    Rectangle()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 1.5, height: height + 3)
                        .offset(x: width * (remaining ? 1 - pace : pace) - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}

/// One limit: label, percentage, bar, and optionally the reset time.
struct LimitRow: View {
    var limit: Limit
    /// In place of the limit's label.
    var title: String?
    var now: Date
    var dimmed: Bool
    var showPace: Bool
    var remaining: Bool
    var showReset = true
    var font: Font = .subheadline
    /// Thinner beside the widgets' smaller text.
    var barHeight: CGFloat = 5

    var body: some View {
        let percent = limit.percent(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? limit.label).lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.percent(percent, remaining: remaining))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Level(percent: percent).color ?? .primary))
            }
            .font(font)
            UsageBar(percent: percent, remaining: remaining, pace: showPace ? limit.elapsedFraction(at: now) : nil, dimmed: dimmed, height: barHeight)
            if showReset {
                HStack {
                    Text(Format.reset(limit.resetsAt, now: now))
                    Spacer(minLength: 4)
                    if let countdown = Format.countdown(limit.resetsAt, now: now) {
                        // In a narrow widget column the date gives way first.
                        Text(countdown).monospacedDigit().layoutPriority(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}
