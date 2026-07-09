import AVFoundation
import SwiftUI
import UIKit

/// Camera viewfinder that reports each decoded QR payload once. Shows a
/// static explainer when no camera is available (simulator) or the user
/// denied access — callers always have the paste fallback next to it.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?

        private let session = AVCaptureSession()
        /// Camera bring-up takes tens–hundreds of ms; keep configuration
        /// and start/stop off the main thread (Apple's AVCam split).
        private let sessionQueue = DispatchQueue(label: "openlv.qr-scanner")
        private var lastCode: String?
        private let fallbackLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .secondarySystemBackground

            fallbackLabel.text = "Camera unavailable — paste the connection link below."
            fallbackLabel.font = .preferredFont(forTextStyle: .footnote)
            fallbackLabel.textColor = .secondaryLabel
            fallbackLabel.textAlignment = .center
            fallbackLabel.numberOfLines = 0
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fallbackLabel)
            NSLayoutConstraint.activate([
                fallbackLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                fallbackLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                fallbackLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])

            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.configureCamera(authorized: granted) }
            }
        }

        private func configureCamera(authorized: Bool) {
            guard authorized else { return }
            sessionQueue.async { [weak self] in
                guard let self, self.wireUpCaptureSession() else { return }
                self.session.startRunning()
                DispatchQueue.main.async { self.installPreviewLayer() }
            }
        }

        /// Runs on `sessionQueue`. The delegate still fires on main.
        private func wireUpCaptureSession() -> Bool {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return false }
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
            output.metadataObjectTypes = [.qr]
            return true
        }

        private func installPreviewLayer() {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            fallbackLabel.isHidden = true
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            (view.layer.sublayers ?? [])
                .compactMap { $0 as? AVCaptureVideoPreviewLayer }
                .forEach { $0.frame = view.bounds }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Allow re-scanning the same QR on a fresh visit (retry
            // after a failed session) — dedupe only within one stay.
            lastCode = nil
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code != lastCode else { return }
            lastCode = code
            onCode?(code)
        }
    }
}
