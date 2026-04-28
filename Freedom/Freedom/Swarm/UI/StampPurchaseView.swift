import BigInt
import SwiftUI

/// Stamp purchase form. State machine lives in `StampService.buyState`;
/// this view only renders + dispatches. Mirrors desktop
/// `stamp-manager.js`'s `renderState` mapping at the case-by-case level.
@MainActor
struct StampPurchaseView: View {
    @Environment(StampService.self) private var stampService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex: Int = StampService.defaultPresetIndex
    @State private var estimatedCostPlur: BigUInt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                presetGrid
                costRow
                purchaseButton
                stateMessage
            }
            .padding(20)
        }
        .navigationTitle("Buy stamp")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedIndex) { await refreshEstimate() }
        .onChange(of: stampService.buyState) { _, new in
            if case .usable = new { dismiss() }
        }
        .onDisappear {
            // Avoid stale "Stamp ready." showing on re-entry. Idle on
            // success path, leave failed/in-flight states alone so a
            // user navigating away mid-buy can come back to them.
            if case .usable = stampService.buyState {
                stampService.resetBuyState()
            }
        }
    }

    // MARK: - Sections

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a preset").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(Array(StampService.presets.enumerated()), id: \.offset) { idx, preset in
                    presetCard(preset, isSelected: idx == selectedIndex)
                        .onTapGesture {
                            if !isLocked { selectedIndex = idx }
                        }
                }
            }
        }
    }

    private func presetCard(_ preset: StampService.Preset, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label).font(.callout).fontWeight(.medium)
                Text(preset.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isLocked ? 0.6 : 1.0)
    }

    @ViewBuilder private var costRow: some View {
        HStack {
            Text("Estimated cost").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let cost = estimatedCostPlur {
                Text(formatBzz(cost)).font(.callout).monospacedDigit()
            } else {
                Text("Estimating…").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var purchaseButton: some View {
        Button {
            Task { await stampService.buy(preset: StampService.presets[selectedIndex]) }
        } label: {
            Label(buttonLabel, systemImage: buttonIcon)
        }
        .buttonStyle(PrimaryActionStyle(isEnabled: canBuy))
        .disabled(!canBuy)
    }

    @ViewBuilder private var stateMessage: some View {
        switch stampService.buyState {
        case .purchasing:
            statusText("Submitting purchase to the network…", tint: .secondary)
        case .waitingForUsable:
            statusText("Purchase confirmed. Waiting for the batch to become usable…", tint: .secondary)
        case .usable:
            statusText("Stamp ready.", tint: .green)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                statusText(msg, tint: .red)
                Button("Try again") { stampService.resetBuyState() }
                    .font(.callout)
            }
        case .idle, .estimating:
            EmptyView()
        }
    }

    private func statusText(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived

    /// Locked while a buy is in flight — preset cards stop responding
    /// to taps and the button shows its mid-flight label. `.estimating`
    /// is included so a fast double-tap during the brief price re-fetch
    /// can't kick off a second `buy` that races the first.
    private var isLocked: Bool {
        switch stampService.buyState {
        case .estimating, .purchasing, .waitingForUsable: return true
        default: return false
        }
    }

    private var canBuy: Bool {
        if isLocked { return false }
        if case .failed = stampService.buyState { return false }
        return estimatedCostPlur != nil
    }

    private var buttonLabel: String {
        switch stampService.buyState {
        case .purchasing: return "Submitting…"
        case .waitingForUsable: return "Activating…"
        default: return "Buy stamp"
        }
    }

    private var buttonIcon: String {
        switch stampService.buyState {
        case .purchasing, .waitingForUsable: return "hourglass"
        default: return "cart.fill"
        }
    }

    private func refreshEstimate() async {
        estimatedCostPlur = nil
        let preset = StampService.presets[selectedIndex]
        estimatedCostPlur = await stampService.estimateCost(for: preset)
    }

    /// PLUR → xBZZ display. 1 BZZ = 1e16 PLUR (bee's `toPLURBigInt`
    /// convention, mirroring desktop's `formatRawTokenBalance(..., 16)`).
    private func formatBzz(_ plur: BigUInt) -> String {
        return BalanceFormatter.format(
            wei: plur,
            decimals: 16,
            symbol: "xBZZ",
            maxFractionDigits: 4
        )
    }
}
