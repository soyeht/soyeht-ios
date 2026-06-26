import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum MacQRCodeImageFactory {
    private static let context = CIContext()
    private static let scale: CGFloat = 12

    static func makeImage(from deepLink: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(deepLink.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: output.extent.width, height: output.extent.height)
        )
    }
}
