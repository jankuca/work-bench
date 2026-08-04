import SwiftUI

/// The empty popover M0 ships.
///
/// Deliberately not a mock of design 2a — a placeholder that looks like the real panel
/// invites judging the design from a drawing that has no data behind it. The real panel,
/// its tokens and its states arrive at M3.
struct PlaceholderPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pull requests")
                .font(.system(size: 13, weight: .semibold))

            Text("Menu bar shell only. The panel, its design tokens and the row layout arrive in M3; the data behind them in M2 and M5.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text("M0 · skeleton & local build")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 440, height: 260, alignment: .topLeading)
    }
}
