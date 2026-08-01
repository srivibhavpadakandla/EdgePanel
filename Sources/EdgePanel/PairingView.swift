import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The "Pair iPhone" window: a QR that the iOS app scans to connect (host + token).
struct PairingView: View {
    let host: String      // HTTPS proxy URL, direct Tailscale address, or loopback
    let token: String
    let onRotate: () -> Void

    private var payload: String {
        var c = URLComponents()
        c.scheme = "edgepanel"; c.host = "pair"
        c.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "token", value: token)]
        return c.string ?? ""
    }

    var body: some View {
        let t = Theme.resolve(.dark)
        VStack(spacing: 16) {
            Text("Pair your iPhone").font(.claude(22, .semibold)).foregroundColor(t.text)
            if let img = Self.qr(payload) {
                Image(nsImage: img).interpolation(.none).resizable()
                    .frame(width: 220, height: 220)
                    .padding(10).background(Color.white).cornerRadius(12)
            }
            VStack(spacing: 3) {
                Text("Keep Tailscale on, then open EdgePanel on iPhone → Scan")
                    .font(.claude(12)).foregroundColor(t.subtext)
                Text(host).font(.system(size: 12, design: .monospaced)).foregroundColor(t.text)
            }
            Text("Or enter the token manually:").font(.claude(11)).foregroundColor(t.subtext)
            Text(token).font(.system(size: 11, design: .monospaced)).foregroundColor(t.subtext)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240)
            Button("Rotate pairing token", action: onRotate)
                .buttonStyle(.borderless).font(.claude(11, .medium)).foregroundColor(t.accent)
        }
        .padding(28)
        .frame(width: 320)
        .background(t.bg)
    }

    static func qr(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
