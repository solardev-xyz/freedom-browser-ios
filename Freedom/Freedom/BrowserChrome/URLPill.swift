import SwiftUI

/// URL bar pill. Idle: tappable host label. Focused: editable TextField
/// with an inline ✕-circle to clear.
///
/// The TextField is always in the view tree (opacity-toggled when idle):
/// `@FocusState.Binding` is a no-op if no focusable view is currently
/// bound, so conditionally rendering the field would mean tap → set
/// focus → nothing focuses since the field doesn't exist yet.
struct URLPill: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let trust: ENSTrust?
    let isLoading: Bool
    let progress: Double
    let displayURL: URL?
    /// True while the chrome is in edit mode. Distinct from `isFocused`
    /// because scroll-dismissing the keyboard drops focus but keeps the
    /// edit-mode UI; alignment of the idle host label needs to follow
    /// edit-mode (leading) vs idle (center) regardless of focus state.
    let isEditing: Bool
    let onSubmit: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void

    static let placeholder = "Search or enter address"

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let trust {
                    TrustShield(trust: trust)
                } else {
                    Color.clear
                }
            }
            .frame(width: 28, height: 28)

            TextField(Self.placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .opacity(isFocused ? 1 : 0)
                .onChange(of: isFocused) { _, focused in
                    if focused { selectAllOnFocus() }
                }
                .overlay {
                    if !isFocused {
                        Button { isFocused = true } label: {
                            idleLabel
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

            if isFocused {
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    isLoading ? onStop() : onReload()
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!isLoading && displayURL == nil)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .glassPill()
        .overlay(alignment: .bottom) {
            if isLoading, progress > 0, progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(y: 0.4, anchor: .bottom)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Select the URL text when focus arrives so the next keystroke
    /// replaces the prefilled URL outright (Safari behavior). The brief
    /// delay lets the underlying `UITextField` finish becoming first
    /// responder — `selectAll(_:)` dispatched too early is a no-op.
    /// Re-checks `isFocused` afterwards so a fast focus handoff
    /// (sheet steals focus) doesn't selectAll the wrong responder.
    private func selectAllOnFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard isFocused else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.selectAll(_:)),
                to: nil, from: nil, for: nil
            )
        }
    }

    @ViewBuilder private var idleLabel: some View {
        let alignment: Alignment = isEditing ? .leading : .center
        if let url = displayURL {
            Text(url.hostOrAbsolute)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: alignment)
        } else {
            Text(Self.placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
