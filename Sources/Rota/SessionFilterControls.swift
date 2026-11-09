import SwiftUI

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
