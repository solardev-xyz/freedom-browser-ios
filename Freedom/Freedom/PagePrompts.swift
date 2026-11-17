import SwiftUI

/// The active tab's page prompts as sheets: wallet (EIP-1193), site
/// permission, Swarm and Radicle approvals. A view can present only one
/// sheet at a time, so these present from the app's root, except while the
/// agent's sheet is on screen (`AgentService.isSheetOnScreen`): then the
/// agent's sheet presents them over itself, so a page the agent operates can
/// still ask for the wallet and the user sees it.
struct PagePromptSheets: ViewModifier {
    @Environment(TabStore.self) private var tabStore
    @Environment(AgentService.self) private var agent
    /// Whether this is the agent sheet's copy.
    let inAgentSheet: Bool

    private var enabled: Bool { inAgentSheet == agent.isSheetOnScreen }
    private var tab: BrowserTab? { enabled ? tabStore.activeTab : nil }

    /// Swipe-dismiss (set to nil) resolves a parked approval as denied: the
    /// single point that resumes its continuation.
    private func approvalBinding(
        get: @escaping () -> ApprovalRequest?,
        deny: @escaping () -> Void
    ) -> Binding<ApprovalRequest?> {
        Binding(get: get, set: { newValue in if newValue == nil { deny() } })
    }

    private var ethereumBinding: Binding<ApprovalRequest?> {
        approvalBinding(get: { tab?.pendingEthereumApproval }, deny: { tab?.resolvePendingApproval(.denied) })
    }

    private var swarmBinding: Binding<ApprovalRequest?> {
        approvalBinding(get: { tab?.pendingSwarmApproval }, deny: { tab?.resolvePendingSwarmApproval(.denied) })
    }

    private var radicleBinding: Binding<ApprovalRequest?> {
        approvalBinding(get: { tab?.pendingRadicleApproval }, deny: { tab?.resolvePendingRadicleApproval(.denied) })
    }

    /// Swipe-dismissing the permission prompt is a dismissal: denied
    /// once, counted toward the session embargo, nothing remembered.
    private var permissionBinding: Binding<SitePermissionRequest?> {
        Binding(
            get: { tab?.pendingPermissionRequest },
            set: { newValue in
                if newValue == nil, let request = tab?.pendingPermissionRequest {
                    request.respond(.dismiss, false)
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: ethereumBinding) { approval in
                EthereumApprovalSheet(approval: approval)
            }
            .sheet(item: permissionBinding) { request in
                SitePermissionPrompt(request: request)
            }
            .sheet(item: swarmBinding) { approval in
                switch approval.kind {
                case .swarmConnect:
                    SwarmConnectSheet(approval: approval)
                case .swarmPublish(let details):
                    SwarmPublishSheet(approval: approval, details: details)
                case .swarmFeedAccess(let details):
                    SwarmFeedAccessSheet(approval: approval, details: details)
                case .swarmMessaging(let details):
                    SwarmMessagingSheet(approval: approval, details: details)
                case .swarmManifest(let details):
                    SwarmManifestSheet(approval: approval, details: details)
                case .connect, .personalSign, .typedData,
                     .sendTransaction, .switchChain,
                     .radicleConnect, .radicleSeed, .radicleSigning:
                    EmptyView()  // routed via the Ethereum / Radicle sheets
                }
            }
            .sheet(item: radicleBinding) { approval in
                switch approval.kind {
                case .radicleConnect:
                    RadicleConnectSheet(approval: approval)
                case .radicleSeed(let rid):
                    RadicleSeedSheet(approval: approval, rid: rid)
                case .radicleSigning:
                    RadicleSigningSheet(approval: approval)
                default:
                    EmptyView()  // other kinds route via their own bindings
                }
            }
    }
}

extension View {
    /// The active tab's page prompts (see `PagePromptSheets`).
    func pagePromptSheets(inAgentSheet: Bool = false) -> some View {
        modifier(PagePromptSheets(inAgentSheet: inAgentSheet))
    }
}

extension BrowserTab {
    /// A page prompt waits for the user (wallet, permission, Swarm, Radicle).
    var hasPendingPrompt: Bool {
        pendingEthereumApproval != nil || pendingSwarmApproval != nil
            || pendingRadicleApproval != nil || pendingPermissionRequest != nil
    }
}
