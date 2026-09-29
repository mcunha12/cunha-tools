import AVFoundation
import AppKit
import CoreImage

// Self-test aid: offscreen render of the overlay chrome with the displayed frame drawn into the video area.
@MainActor
enum OverlaySnapshot {
    static func write(root: OverlayRootView, frame: CVPixelBuffer, to url: URL) {
        let scale: CGFloat = 2
        let size = root.bounds.size
        guard size.width > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        root.strip.setControlsVisible(true, animated: false)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        root.layer?.render(in: context)
        let image = CIImage(cvPixelBuffer: frame)
        if let video = CIContext().createCGImage(image, from: image.extent) {
            context.saveGState()
            context.addPath(CGPath(roundedRect: root.bounds, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.clip()
            context.draw(video, in: AVMakeRect(aspectRatio: image.extent.size, insideRect: root.videoView.frame))
            context.restoreGState()
        }
        root.strip.setControlsVisible(false, animated: false)
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, output, nil)
        CGImageDestinationFinalize(destination)
        SelfTest.log("render offscreen da janela \(Int(size.width))x\(Int(size.height)) salvo em \(url.path)")
    }
}
