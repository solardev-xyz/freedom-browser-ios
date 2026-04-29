import BigInt
import SwiftUI

/// Extend an existing batch's TTL (duration tab) or capacity (size tab).
/// State machine lives in `StampService.extendState`; this view only
/// renders + dispatches. Mirrors `StampPurchaseView`'s shape and reads
/// its batch from `stampService.stamps` so a successful extend
/// (`refreshStamps`) propagates without re-pushing.
@MainActor
struct StampExtendView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case duration = "Duration"
        case size = "Size"
        var id: String { rawValue }
    }

    let batchID: String
    @Environment(StampService.self) private var stampService
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .duration
    @State private var durationIndex: Int = StampService.defaultDurationExtendIndex
    /// Pre-selected in `.onAppear` from the batch's current depth so
    /// the highlighted preset is the next-up tier above current size.
    /// Stays `nil` if every preset is ≤ current — drives the empty
    /// state at `sizeSection`.
    @State private var sizeIndex: Int?
    @State private var estimatedCostPlur: BigUInt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let batch = stampService.batch(id: batchID) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isLocked)

                    switch mode {
                    case .duration: durationSection
                    case .size: sizeSection(for: batch)
                    }
                    costRow
                    confirmButton(for: batch)
                    stateMessage
                } else {
                    Text("Stamp no longer present.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Extend stamp")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: estimateKey) { await refreshEstimate() }
        .onAppear { initSizeIndex() }
        .onChange(of: stampService.extendState) { _, new in
            if case .completed = new { dismiss() }
        }
        .onDisappear {
            // Avoid stale "Done." showing on re-entry. Idle on success
            // path; leave failed/in-flight states alone so a user
            // navigating away mid-patch can come back to them.
            if case .completed = stampService.extendState {
                stampService.resetExtendState()
            }
        }
    }

    // MARK: - Sections

    private var durationSection: some View {
        VStack(spacing: 8) {
            ForEach(Array(StampService.durationExtendPresets.enumerated()), id: \.offset) { idx, preset in
                presetRow(label: preset.label,
                          isSelected: idx == durationIndex,
                          isDisabled: false) {
                    if !isLocked { durationIndex = idx }
                }
            }
        }
    }

    @ViewBuilder
    private func sizeSection(for batch: PostageBatch) -> some View {
        if !hasSomeValidSize(for: batch) {
            Text("Already at the largest preset (25 GB).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(spacing: 8) {
                ForEach(Array(StampService.sizeExtendPresets.enumerated()), id: \.offset) { idx, preset in
                    let disabled = !canExtendToSize(preset.sizeGB, from: batch)
                    presetRow(label: preset.label,
                              isSelected: idx == sizeIndex,
                              isDisabled: disabled) {
                        if !isLocked && !disabled { sizeIndex = idx }
                    }
                }
            }
        }
    }

    private func presetRow(
        label: String, isSelected: Bool, isDisabled: Bool, onTap: @escaping () -> Void
    ) -> some View {
        let opacity: Double = {
            if isDisabled { return 0.4 }
            if isLocked { return 0.6 }
            return 1.0
        }()
        return HStack {
            Text(label).font(.callout).fontWeight(.medium)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color(.tertiarySystemBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var costRow: some View {
        HStack {
            Text("Estimated cost").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let cost = estimatedCostPlur {
                Text(BalanceFormatter.bzz(plur: cost))
                    .font(.callout).monospacedDigit()
            } else {
                Text(canEstimate ? "Estimating…" : "—")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func confirmButton(for batch: PostageBatch) -> some View {
        Button {
            Task { await dispatchExtend(for: batch) }
        } label: {
            Label(buttonAppearance.label, systemImage: buttonAppearance.icon)
        }
        .buttonStyle(PrimaryActionStyle(isEnabled: canConfirm))
        .disabled(!canConfirm)
    }

    @ViewBuilder private var stateMessage: some View {
        switch stampService.extendState {
        case .estimating:
            stampStatusText("Pricing the extension…", tint: .secondary)
        case .patching:
            stampStatusText("Submitting to the network…", tint: .secondary)
        case .completed:
            stampStatusText("Done.", tint: .green)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                stampStatusText(msg, tint: .red)
                Button("Try again") { stampService.resetExtendState() }
                    .font(.callout)
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Derived

    private var isLocked: Bool {
        switch stampService.extendState {
        case .estimating, .patching: return true
        default: return false
        }
    }

    /// Cache key for `.task(id:)` — re-runs `refreshEstimate` when the
    /// tab or selected preset changes.
    private var estimateKey: String {
        switch mode {
        case .duration: return "d-\(durationIndex)"
        case .size: return "s-\(sizeIndex ?? -1)"
        }
    }

    /// Cost row reads "—" instead of "Estimating…" when there's no
    /// valid pick to estimate (size tab with no usable preset).
    private var canEstimate: Bool {
        switch mode {
        case .duration: return true
        case .size: return sizeIndex != nil
        }
    }

    private var canConfirm: Bool {
        if isLocked { return false }
        if case .failed = stampService.extendState { return false }
        guard estimatedCostPlur != nil else { return false }
        switch mode {
        case .duration: return true
        case .size: return sizeIndex != nil
        }
    }

    private var buttonAppearance: (label: String, icon: String) {
        switch stampService.extendState {
        case .estimating: return ("Pricing…", "hourglass")
        case .patching: return ("Submitting…", "hourglass")
        default: return ("Extend stamp", "arrow.up.circle.fill")
        }
    }

    // MARK: - Behaviour

    /// Pre-selects the next-up size tier above the batch's current
    /// depth. If every preset's depth ≤ current, leaves `sizeIndex`
    /// nil — the size tab renders an empty-state instead.
    private func initSizeIndex() {
        guard sizeIndex == nil, let batch = stampService.batch(id: batchID) else { return }
        sizeIndex = StampService.sizeExtendPresets.firstIndex {
            canExtendToSize($0.sizeGB, from: batch)
        }
    }

    private func canExtendToSize(_ targetGB: Int, from batch: PostageBatch) -> Bool {
        let newDepth = StampMath.depthForSize(bytes: targetGB * 1_000_000_000)
        return newDepth > batch.depth
    }

    private func hasSomeValidSize(for batch: PostageBatch) -> Bool {
        StampService.sizeExtendPresets.contains {
            canExtendToSize($0.sizeGB, from: batch)
        }
    }

    private func refreshEstimate() async {
        estimatedCostPlur = nil
        guard let batch = stampService.batch(id: batchID) else { return }
        switch mode {
        case .duration:
            let preset = StampService.durationExtendPresets[durationIndex]
            estimatedCostPlur = await stampService.estimateExtendDurationCost(
                batch: batch, additionalDays: preset.additionalDays
            )
        case .size:
            guard let idx = sizeIndex else { return }
            let preset = StampService.sizeExtendPresets[idx]
            estimatedCostPlur = stampService.estimateExtendSizeCost(
                batch: batch, targetSizeGB: preset.sizeGB
            )
        }
    }

    private func dispatchExtend(for batch: PostageBatch) async {
        switch mode {
        case .duration:
            let preset = StampService.durationExtendPresets[durationIndex]
            await stampService.extendDuration(
                batch: batch, additionalDays: preset.additionalDays
            )
        case .size:
            guard let idx = sizeIndex else { return }
            let preset = StampService.sizeExtendPresets[idx]
            await stampService.extendSize(
                batch: batch, targetSizeGB: preset.sizeGB
            )
        }
    }

}
