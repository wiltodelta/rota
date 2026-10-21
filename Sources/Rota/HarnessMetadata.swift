import RotaCore
import SwiftUI

/// A row's primary identity, with its existing status in a separate corner badge.
struct HarnessStatusIcon<Status: View>: View {
    @Environment(\.interfaceScale) private var metrics
    let harness: Harness
    let status: Status

    init(harness: Harness, @ViewBuilder status: () -> Status) {
        self.harness = harness
        self.status = status()
    }

    var body: some View {
        HarnessLogo(harness: harness, size: 20, monochrome: true)
            .frame(width: metrics.points(24), height: metrics.points(24))
            .overlay(alignment: .bottomTrailing) {
                status
                    .padding(metrics.points(1.5))
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
            }
    }
}

/// A small activity badge whose contrast does not depend on a list's selection tint.
struct RunActivityIndicator: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 :
                context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(style: StrokeStyle(lineWidth: metrics.points(1.2), lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .padding(metrics.points(0.6))
                .frame(width: metrics.points(8), height: metrics.points(8))
        }
        .accessibilityIdentifier("runActivityIndicator")
    }
}

/// A compact harness identity beside existing metadata, with its name kept in the text.
struct HarnessMetadata: View {
    @Environment(\.interfaceScale) private var metrics
    let harness: Harness
    let text: String

    var body: some View {
        HStack(spacing: metrics.points(4)) {
            HarnessLogo(harness: harness, size: 12, monochrome: true).fixedSize()
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A harness's own mark (`HarnessLogos.xcassets`, sources in `docs/harness-logos.md`):
/// Claude in its orange, the others in the text color; a shell gets the terminal glyph.
struct HarnessLogo: View {
    @Environment(\.interfaceScale) private var metrics
    let harness: Harness
    var size: CGFloat = 14
    var monochrome = false

    var body: some View {
        Group {
            if harness == .shell || harness == .antigravity {
                Image(systemName: harness == .shell ? "apple.terminal" : "sparkles")
                    .resizable()
                    .scaledToFit()
            } else {
                Image("harness-" + harness.rawValue)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .foregroundStyle(harness == .claude && !monochrome ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
                         : Color.primary)
        .frame(width: metrics.points(size), height: metrics.points(size))
        .accessibilityHidden(true)
    }
}
