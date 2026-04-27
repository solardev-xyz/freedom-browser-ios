import SwiftUI

/// Lifecycle of a single checklist step. Top-level so callers can
/// type-annotate without specialising the row's generic.
enum PublishStepStatus {
    case pending    // earlier step blocking this one
    case active     // user can interact here
    case waiting    // user has nothing to do; we're polling
    case completed  // done
}

/// Reusable checklist step row used by `PublishSetupView`. Step status
/// drives the leading icon (○ pending, ▷ active, ⏳ waiting, ✓ complete);
/// `actions` is whatever inline UI the active step needs (preset chips,
/// progress bar, "Buy stamps" button, etc.).
@MainActor
struct PublishStepRow<Actions: View>: View {
    let number: Int
    let title: String
    let summary: String
    let status: PublishStepStatus
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("Step \(number)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .active || status == .waiting {
                    actions()
                        .padding(.top, 4)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(status == .pending ? 0.5 : 1.0)
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
        case .active:
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        case .waiting:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
    }
}

