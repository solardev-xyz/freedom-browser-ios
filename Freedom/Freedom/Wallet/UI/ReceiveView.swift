import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import web3

/// QR + copy entry point for receiving funds. The QR carries the plain
/// hex address — addresses are chain-agnostic at the bytes layer (same
/// key, same address on every EVM chain), and EIP-681 URIs aren't
/// universally recognized by simpler scanners.
@MainActor
struct ReceiveView: View {
    @Environment(Vault.self) private var vault
    @Environment(ENSResolver.self) private var ensResolver

    @State private var address: String?
    @State private var primaryName: String?
    @State private var qrImage: UIImage?
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let primaryName {
                    Text(primaryName)
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                }
                qrCard
                if let address {
                    AddressPill(address: address)
                }
                copyButton
                Text("Send any EVM asset to this address — same address works on Mainnet, Gnosis, and any other EVM chain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAddress() }
    }

    @ViewBuilder private var qrCard: some View {
        if let qrImage {
            Image(uiImage: qrImage)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR code containing your wallet address")
        } else {
            ProgressView()
                .frame(width: 240 + 32, height: 240 + 32)
        }
    }

    private var copyButton: some View {
        Button(action: copyAddress) {
            Label(
                didCopy ? "Copied" : "Copy address",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(PrimaryActionStyle(isEnabled: address != nil))
        .disabled(address == nil)
    }

    private func loadAddress() async {
        guard let derived = try? vault.signingKey(at: .mainUser).ethereumAddress else { return }
        self.address = derived
        self.qrImage = Self.generateQR(content: derived)
        // ENS reverse runs in the background — we already show address
        // and QR, the name is purely additive.
        if let name = try? await ensResolver.reverseResolve(address: EthereumAddress(derived)) {
            self.primaryName = name
        }
    }

    private func copyAddress() {
        guard let address else { return }
        UIPasteboard.general.string = address
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation { didCopy = false }
        }
    }

    /// 10× scale so the 240pt rendering is crisp at retina densities.
    /// `interpolation(.none)` on the SwiftUI Image disables smoothing.
    private static func generateQR(content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
