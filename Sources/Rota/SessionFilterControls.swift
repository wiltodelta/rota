import SwiftUI

/// Packs tokens in reading order, wrapping only when the next token will not fit.
struct SessionFilterFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0,
                      height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            let frame = CGRect(origin: origin, size: size)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}

/// A session-scoped menu; its filled symbol indicates that the history is filtered.
struct SessionFilterMenu: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    let filter: SessionFilters
    let onSelection: () -> Void

    var body: some View {
        Menu {
            ForEach(SessionFilter.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { filter.contains(category) },
                    set: { _ in
                        model.toggleSessionFilter(category)
                        onSelection()
                    }
                ))
            }
        } label: {
            Image(systemName: filter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .interfaceSystemFont(size: 16)
                .foregroundStyle(filter == .all ? Color.secondaryText : Color.accentColor)
                .frame(width: metrics.points(28), height: metrics.points(28))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(interactions: .edit)
        .onMoveCommand { direction in
            let next = filter.moved(by: direction == .up || direction == .left ? -1 : 1)
            if filter != SessionFilters(next) { model.selectSessionFilter(next) }
        }
        .accessibilityLabel("Filter Sessions")
        .accessibilityValue(filter.title)
        .accessibilityIdentifier("sessionFilter")
        .help("Select one or more categories. Arrow keys choose a single category; Tab browses sessions.")
    }
}

/// Each selected category has its own accessible removal action.
struct SessionFilterToken: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    let filter: SessionFilter

    var body: some View {
        Button {
            model.toggleSessionFilter(filter)
        } label: {
            HStack(spacing: metrics.points(8)) {
                Text(filter.title).foregroundStyle(Color.primary)
                Image(systemName: "xmark").foregroundStyle(Color.secondaryText)
                    .interfaceSystemFont(size: 9, weight: .semibold)
            }
            .interfaceFont(.callout)
            .padding(.horizontal, metrics.points(10))
            .frame(minHeight: metrics.points(28))
            .background(Color.primary.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(filter.title) Filter")
        .accessibilityValue(filter.title)
        .accessibilityIdentifier("clearSessionFilter-\(filter.rawValue)")
        .help("Remove this category")
    }
}
