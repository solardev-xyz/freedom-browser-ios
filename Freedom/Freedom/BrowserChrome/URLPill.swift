import SwiftUI

/// URL bar pill. TrustShield leading, editable text middle, reload/stop
/// trailing. Hairline progress at the bottom edge while loading.
struct URLPill: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let trust: ENSTrust?
    let isLoading: Bool
    let progress: Double
    let hasURL: Bool
    let onSubmit: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void

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

            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isFocused)
                .onSubmit(onSubmit)

            Button {
                isLoading ? onStop() : onReload()
            } label: {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!isLoading && !hasURL)
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
}
