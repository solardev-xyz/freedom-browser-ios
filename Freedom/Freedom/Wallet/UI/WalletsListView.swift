import SwiftUI

/// The wallet picker (the Send screen's asset picker, for wallets): tap
/// selects and pops back; swipe renames or hides; Edit reorders; hidden
/// wallets sit at the bottom with a Show action; Add wallet derives the
/// next one under the recovery phrase.
@MainActor
struct WalletsListView: View {
    @Environment(UserWalletStore.self) private var wallets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode
    @State private var renaming: UserWallet?
    @State private var isAdding = false
    @State private var nameDraft = ""

    var body: some View {
        List {
            Section {
                ForEach(wallets.visibleWallets) { wallet in
                    Button {
                        if editMode?.wrappedValue.isEditing == true { return }
                        wallets.setActive(index: wallet.index)
                        dismiss()
                    } label: {
                        row(wallet)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !wallet.isMain {
                            Button { wallets.hide(index: wallet.index) } label: { Label("Hide", systemImage: "eye.slash") }
                                .tint(.orange)
                        }
                        Button {
                            nameDraft = wallet.name
                            renaming = wallet
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .moveDisabled(wallet.isMain)
                }
                .onMove { source, destination in
                    wallets.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                Text("Every wallet comes from your recovery phrase. Main Wallet stays first.")
            }

            if !wallets.hiddenWallets.isEmpty {
                Section("Hidden wallets") {
                    ForEach(wallets.hiddenWallets) { wallet in
                        HStack {
                            row(wallet)
                            Button("Show") { wallets.unhide(index: wallet.index) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Button {
                    nameDraft = ""
                    isAdding = true
                } label: {
                    Label("Add wallet", systemImage: "plus")
                }
            } footer: {
                Text("Derives \(UserWallet.defaultName(for: (wallets.wallets.map(\.index).max() ?? 0) + 1)) from the same recovery phrase. Hidden wallets keep their place; a new one never reuses it.")
            }
        }
        .navigationTitle("Wallets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if wallets.visibleWallets.count > 2 { EditButton() }
            }
        }
        .alert("Rename wallet", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                if let renaming { wallets.rename(index: renaming.index, to: nameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("New wallet", isPresented: $isAdding) {
            TextField("Name", text: $nameDraft)
            Button("Add") {
                wallets.addWallet(name: nameDraft)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new wallet under the same recovery phrase. It becomes the active one.")
        }
    }

    private func row(_ wallet: UserWallet) -> some View {
        HStack(spacing: 12) {
            Image(systemName: wallet.isMain ? "wallet.bifold.fill" : "wallet.bifold")
                .font(.title3)
                .foregroundStyle(wallet.hidden ? .secondary : .primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name).font(.callout.weight(.semibold)).foregroundStyle(wallet.hidden ? .secondary : .primary)
                Text(wallets.address(of: wallet)?.shortenedHex() ?? "Locked")
                    .font(.caption2).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            if wallet.index == wallets.activeIndex {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
