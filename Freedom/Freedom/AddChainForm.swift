import SwiftUI

/// Manual "add chain" form. Collects the minimum payload `ChainStore`
/// needs to construct a `ChainRecord`: chain ID, display name, native
/// asset metadata, explorer URL, and at least one RPC URL. Validation
/// runs inline (Add button stays disabled until everything is valid)
/// and the chain-ID-collision case surfaces inline via the store's
/// typed error.
///
/// Chainlist integration (Phase 3-WP3) presents this same view via the
/// `prefilled` init so a chainlist pick lands the user on a populated
/// form they can review before committing.
struct AddChainForm: View {
    /// Optional pre-fill payload. Chainlist search hands this in;
    /// manual launch leaves it nil and the user fills every field.
    /// Hashable so the enclosing `AddChainRoute.form(_:)` case can be
    /// a NavigationStack path value.
    struct Prefill: Hashable {
        let chainID: Int
        let displayName: String
        let nativeName: String
        let nativeSymbol: String
        let nativeDecimals: Int
        let explorerBase: String
        let rpcURLs: [String]
    }

    let prefill: Prefill?

    @Environment(ChainStore.self) private var chainStore
    /// Shared settings navigation path. On successful Add the form
    /// trims every consecutive Add Chain step from the top so the
    /// chainlist search view and the form pop together, landing the
    /// user back on the chain list with the new entry visible.
    @Environment(\.settingsPath) private var settingsPath

    @State private var chainIDText: String
    @State private var displayName: String
    @State private var nativeName: String
    @State private var nativeSymbol: String
    @State private var nativeDecimalsText: String
    @State private var explorerURLText: String
    @State private var rpcURLs: [String]
    @State private var newRPCText: String = ""
    @State private var pollIntervalText: String = "12"
    @State private var submitError: String?

    init(prefill: Prefill? = nil) {
        self.prefill = prefill
        _chainIDText = State(initialValue: prefill.map { String($0.chainID) } ?? "")
        _displayName = State(initialValue: prefill?.displayName ?? "")
        _nativeName = State(initialValue: prefill?.nativeName ?? "")
        _nativeSymbol = State(initialValue: prefill?.nativeSymbol ?? "")
        _nativeDecimalsText = State(initialValue: prefill.map { String($0.nativeDecimals) } ?? "18")
        _explorerURLText = State(initialValue: prefill?.explorerBase ?? "")
        _rpcURLs = State(initialValue: prefill?.rpcURLs ?? [])
    }

    // MARK: - Validation

    private var chainID: Int? {
        guard let id = Int(chainIDText), id > 0 else { return nil }
        return id
    }

    /// EIP-155 decimals range is open-ended, but real assets stay in
    /// [0, 36]. Clamping at 36 stops a typo'd 1800 from later overflowing
    /// `pow(10, decimals)` in balance formatting.
    private var nativeDecimals: Int? {
        guard let d = Int(nativeDecimalsText), (0...36).contains(d) else { return nil }
        return d
    }

    /// Same range `TransactionService.awaitConfirmation` will tolerate
    /// for poll cadence — 1s through 10 minutes covers every real chain.
    private var pollIntervalSeconds: Int? {
        guard let s = Int(pollIntervalText), (1...600).contains(s) else { return nil }
        return s
    }

    private var canSubmit: Bool {
        chainID != nil
            && displayName.trimmedNonEmpty
            && nativeName.trimmedNonEmpty
            && nativeSymbol.trimmedNonEmpty
            && nativeDecimals != nil
            && isValidWebURL(explorerURLText)
            && !rpcURLs.isEmpty
            && pollIntervalSeconds != nil
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section("Chain") {
                formField("Chain ID", placeholder: "137", text: $chainIDText, keyboard: .numberPad)
                formField("Display Name", placeholder: "Polygon", text: $displayName)
                formField("Poll Interval (s)", placeholder: "12", text: $pollIntervalText, keyboard: .numberPad)
            }
            Section("Native Asset") {
                formField("Name", placeholder: "Polygon", text: $nativeName)
                formField("Symbol", placeholder: "POL", text: $nativeSymbol)
                formField("Decimals", placeholder: "18", text: $nativeDecimalsText, keyboard: .numberPad)
            }
            Section("Explorer") {
                TextField("https://polygonscan.com", text: $explorerURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.caption).monospaced()
            }
            Section {
                ForEach(rpcURLs, id: \.self) { url in
                    Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                }
                .onDelete { offsets in rpcURLs.remove(atOffsets: offsets) }
                HStack {
                    TextField("https://rpc.example", text: $newRPCText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption).monospaced()
                    Button { addRPC() } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                    .disabled(!isValidWebURL(newRPCText))
                }
            } header: {
                Text("RPC Providers")
            } footer: {
                Text("At least one well-formed http(s) URL is required.")
            }
            if let submitError {
                Section { Text(submitError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add Chain")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: submit).disabled(!canSubmit)
            }
        }
    }

    private func formField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Actions

    private func addRPC() {
        let trimmed = newRPCText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidWebURL(trimmed) else { return }
        let lower = trimmed.lowercased()
        if !rpcURLs.contains(where: { $0.lowercased() == lower }) {
            rpcURLs.append(trimmed)
        }
        newRPCText = ""
    }

    private func submit() {
        guard let id = chainID,
              let decimals = nativeDecimals,
              let poll = pollIntervalSeconds else { return }
        do {
            try chainStore.addChain(
                id: id,
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                nativeName: nativeName.trimmingCharacters(in: .whitespaces),
                nativeSymbol: nativeSymbol.trimmingCharacters(in: .whitespaces),
                nativeDecimals: decimals,
                explorerBase: explorerURLText.trimmingCharacters(in: .whitespacesAndNewlines),
                pollIntervalSeconds: poll,
                rpcURLs: rpcURLs
            )
            // Trim every Add Chain step from the top of the settings
            // path — chainlist search + this form — so the user lands
            // back on the chain list in one animation instead of
            // stepping back through the chainlist results.
            while let top = settingsPath.wrappedValue.last, top.isAddChainStep {
                settingsPath.wrappedValue.removeLast()
            }
        } catch ChainStore.AddChainError.duplicateID(let existing) {
            submitError = "A chain with ID \(existing) already exists. Edit it from the chain list instead."
        } catch {
            submitError = "Failed to add chain: \(error.localizedDescription)"
        }
    }

    /// Stricter than `URL(string:)` alone — that accepts almost anything
    /// (including a bare host with no scheme). We require `http`/`https`
    /// + a non-empty host so a typo doesn't sneak through to the pool
    /// where it'd silently be dropped at normalize time.
    private func isValidWebURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}

private extension String {
    var trimmedNonEmpty: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
