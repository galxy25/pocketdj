import SwiftUI
import CoreImage.CIFilterBuiltins

/// A scannable QR on a white rounded card (the padding doubles as the spec's quiet
/// zone) — the shared twin of `JukeboxQRView` for non-jukebox surfaces (MwF share).
struct PDJQRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let cg = Self.qrImage(for: text) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 80)).foregroundStyle(Theme.bg)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityLabel("QR code")
    }

    static func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer-scale the ~30px module grid up so each module stays a sharp square.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
