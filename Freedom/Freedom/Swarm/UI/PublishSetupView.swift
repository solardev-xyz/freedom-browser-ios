import SwarmKit
import SwiftUI

/// Three-step checklist that takes a user from a read-only node to one
/// with an active storage plan. Step 1 is the node-side funding flow
/// (`StorageFundingView`): the user sends plain xDAI to the node wallet
/// and the node buys the plan, registers it, and deploys and funds its
/// chequebook by itself. Step 2 watches the node restart with chain
/// access (the gateway loads the plan and the chequebook at start; ant
/// reports ready almost at once, the `/chainstate` percent only shows
/// if it ever lags). Step 3 is the chequebook confirmation, read from
/// the restarted node.
@MainActor
struct PublishSetupView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(StampService.self) private var stampService
    @Environment(StorageFundingController.self) private var funding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                step1
                step2
                step3
            }
            .padding(20)
        }
        .navigationTitle("Setup publishing")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Steps

    private var step1: some View {
        PublishStepRow(
            number: 1,
            title: "Fund your storage",
            summary: step1Copy,
            status: step1Status
        ) {
            StorageFundingView(embedded: true)
        }
    }

    private var step2: some View {
        PublishStepRow(
            number: 2,
            title: "Restarting your node",
            summary: step2Copy,
            status: step2Status
        ) {
            Group {
                if case .syncingPostage(let percent, _, _) = beeReadiness.state {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    private var step3: some View {
        PublishStepRow(
            number: 3,
            title: "Chequebook deployed",
            summary: step3Copy,
            status: step3Status
        ) { EmptyView() }
    }

    // MARK: - Step copy + status

    private var step1Copy: String {
        if step1Status == .completed {
            return "Done. Your node holds a storage plan and runs in light mode."
        }
        return "Pick a plan and send xDAI to your node. It buys the plan — swapping xDAI for xBZZ if it needs to — and sets up its chequebook on its own."
    }

    private var step2Copy: String {
        if case .syncingPostage(let percent, let lastSynced, let head) = beeReadiness.state {
            if head > 0 {
                return "\(percent)% · block \(lastSynced.formatted()) of \(head.formatted())"
            }
            return "Block \(lastSynced.formatted())"
        }
        if case .startingUp = beeReadiness.state {
            return "Connecting to Gnosis…"
        }
        if step2Status == .completed { return "Done. Your node has chain access and loaded the plan." }
        return "Your node restarts with chain access and loads the plan and its chequebook. Usually well under a minute — keep the app open."
    }

    private var step3Copy: String {
        // The address can linger from an earlier session; show it only
        // once the restarted node has confirmed it.
        if step3Status == .completed, let addr = beeReadiness.chequebookAddress {
            return "Chequebook \(addr.shortenedHex())"
        }
        // Reached `.ready` but the one-shot address fetch failed —
        // the chequebook exists (the node wouldn't be ready otherwise),
        // we just couldn't display it. Don't show the pending copy.
        if step3Status == .completed { return "Chequebook deployed." }
        return "Confirms once your node is back."
    }

    /// Step 1 is done once a plan came through this flow or the node
    /// already reports a usable stamp (returning user). Ultralight
    /// users with no plan land here.
    private var step1Status: PublishStepStatus {
        if funding.step == .done || stampService.hasUsableStamps { return .completed }
        return .active
    }

    private var step2Status: PublishStepStatus {
        guard step1Status == .completed else { return .pending }
        if settings.beeNodeMode == .ultraLight { return .waiting }
        switch beeReadiness.state {
        case .browsingOnly, .initializing, .startingUp, .syncingPostage: return .waiting
        case .ready: return .completed
        }
    }

    private var step3Status: PublishStepStatus {
        // Auto-completes on .ready (`/chequebook/address` from the
        // restarted node is the first verifiable signal that step 1's
        // deploy succeeded).
        step2Status == .completed ? .completed : .pending
    }
}
