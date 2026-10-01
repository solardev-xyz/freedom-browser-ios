import SwarmKit
import SwiftUI

/// Two-step checklist that takes a user from a read-only node to one
/// with an active storage plan. Step 1 is the node-side funding flow
/// (`StorageFundingView`): the user sends plain xDAI to the node wallet
/// and the node buys the plan, registers it, and deploys and funds its
/// chequebook by itself. Step 2 waits for the network to see the batch:
/// the gateway lists it at once but reports it usable only after bee's
/// block window (about a minute). The node always has chain access, so
/// there is no mode switch and no restart.
@MainActor
struct PublishSetupView: View {
    @Environment(BeeReadiness.self) private var beeReadiness
    @Environment(StampService.self) private var stampService
    @Environment(StorageFundingController.self) private var funding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                step1
                step2
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
            title: "Plan ready",
            summary: step2Copy,
            status: step2Status
        ) { EmptyView() }
    }

    // MARK: - Step copy + status

    private var step1Copy: String {
        if step1Status == .completed {
            return "Done. Your node holds a storage plan."
        }
        return "Pick a plan and send xDAI to your node. It buys the plan — swapping xDAI for xBZZ if it needs to — and sets up its chequebook on its own."
    }

    private var step2Copy: String {
        switch step2Status {
        case .completed:
            if let addr = beeReadiness.chequebookAddress {
                return "Done. You can publish. Chequebook \(addr.shortenedHex())"
            }
            return "Done. You can publish."
        case .waiting:
            return "The network confirms your plan. About a minute — keep the app open."
        case .pending, .active:
            return "Confirms once the plan is bought."
        }
    }

    /// Step 1 is done once a plan came through this flow or the node
    /// already reports a usable stamp (returning user).
    private var step1Status: PublishStepStatus {
        if funding.step == .done || stampService.hasUsableStamps { return .completed }
        return .active
    }

    private var step2Status: PublishStepStatus {
        guard step1Status == .completed else { return .pending }
        return stampService.hasUsableStamps ? .completed : .waiting
    }
}
