import SwiftUI

/// Kind → sheet dispatch for Ethereum approvals, shared by the dapp-tab
/// binding and the openlv session's binding in ContentView — one place
/// that maps approval kinds to their sheets.
@MainActor
struct EthereumApprovalSheet: View {
    let approval: ApprovalRequest

    var body: some View {
        switch approval.kind {
        case .connect:
            ApproveConnectSheet(approval: approval)
        case .personalSign(let preview):
            ApproveSignSheet(approval: approval, kind: .personalSign(preview))
        case .typedData(let typed):
            ApproveSignSheet(approval: approval, kind: .typedData(typed))
        case .sendTransaction(let details):
            ApproveTxSheet(approval: approval, details: details)
        case .switchChain(let details):
            ApproveChainSwitchSheet(approval: approval, details: details)
        case .swarmConnect, .swarmPublish, .swarmFeedAccess, .swarmMessaging:
            EmptyView()  // routed via the swarm approval binding's sheet
        }
    }
}
