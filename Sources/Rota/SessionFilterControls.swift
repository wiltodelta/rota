import SwiftUI

/// A session-scoped menu; its filled symbol indicates that the history is filtered.
struct SessionFilterMenu: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    let filter: SessionFilter

    var body: some View {
        Menu {
            Picker("Session Filter", selection: Binding(
                get: { filter },
                set: { model.selectSessionFilter($0) }
            )) {
                ForEach(SessionFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            .pickerStyle(.inline)
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
            if next != filter { model.selectSessionFilter(next) }
        }
        .accessibilityLabel("Filter Sessions")
        .accessibilityValue(filter.title)
        .accessibilityIdentifier("sessionFilter")
        .help("Filter sessions. Use arrow keys to change the filter, then Tab to browse sessions.")
    }
}

/// The active condition stays separate from the header so its reset action remains accessible.
struct SessionFilterToken: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    let filter: SessionFilter

    var body: some View {
        Button {
            model.selectSessionFilter(.all)
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
        .accessibilityLabel("Show All Sessions")
        .accessibilityValue(filter.title)
        .accessibilityIdentifier("clearSessionFilter")
        .help("Show all sessions")
    }
}
