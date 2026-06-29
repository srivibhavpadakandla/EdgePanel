import SwiftUI
import AVFoundation

/// Live camera QR scanner. Returns the decoded string. (Camera is unavailable in
/// the Simulator — manual entry remains the fallback in the pairing sheet.)
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coord { Coord(onScan: onScan) }
    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.coord = context.coordinator; return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coord: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !fired,
                  let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let s = obj.stringValue else { return }
            fired = true
            onScan(s)
        }
    }
}

final class ScannerVC: UIViewController {
    var coord: QRScanner.Coord?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "edgepanel.qr.session")   // serialize start/stop
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Gate on camera authorization first — a DENIED/restricted camera otherwise yields a
        // silent black screen (the device + input succeed, but startRunning produces no frames).
        // Show the guidance/manual-entry fallback instead.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureSession() : self.showUnavailable()
                }
            }
        default:
            showUnavailable()   // denied / restricted
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showUnavailable(); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { showUnavailable(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coord, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        view.setNeedsLayout()   // size the preview layer now that it exists (after async grant)
        sessionQueue.async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }
    deinit { sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } } }

    private func showUnavailable() {
        let label = UILabel()
        label.text = "Camera unavailable.\nEnter the address + token below."
        label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}
