import AppKit
import ColorComposerCore

/// Native macOS printing for a composited image, using `NSPrintOperation`.
///
/// The image is embedded in a trivial `NSView` whose bounds match the intended
/// physical print size, so the print dialog honors the artwork's dimensions and
/// the user can scale via standard printer-driver options.
enum PrintSupport {

    /// Presents the native print dialog for `raster` at a given physical size.
    static func print(
        _ raster: RGBAImage,
        physicalSizeMM: CGSize,
        overlay: PrintOverlayOptions = PrintOverlayOptions(),
        title: String = "ColorMatching"
    ) {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: physicalSizeMM.width, height: physicalSizeMM.height),
            options: overlay
        )
        guard layout.canvasSize.width > 0, layout.canvasSize.height > 0 else { return }
        guard let view = PrintableImageView(raster: raster, layout: layout) else { return }

        // Points (1 pt = 1/72 inch; 1 inch = 25.4 mm).
        let pointsPerMM = 72.0 / 25.4
        view.frame = NSRect(
            x: 0, y: 0,
            width: layout.canvasSize.width * pointsPerMM,
            height: layout.canvasSize.height * pointsPerMM
        )

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        // Keep reasonable default margins; the user can still adjust in the panel.
        printInfo.leftMargin = max(printInfo.leftMargin, 18)
        printInfo.rightMargin = max(printInfo.rightMargin, 18)
        printInfo.topMargin = max(printInfo.topMargin, 18)
        printInfo.bottomMargin = max(printInfo.bottomMargin, 18)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.canSpawnSeparateThread = true
        operation.run()
    }
}

/// A simple view that draws an image filling its bounds, used as the print
/// subject so the artwork is rasterized at the printer's resolution.
private final class PrintableImageView: NSView {
    private let image: NSImage
    private let bleedSlices: BleedSlices?
    private let layout: PrintLayout

    init?(raster: RGBAImage, layout: PrintLayout) {
        guard let image = ImageUtilities.nsImage(from: raster) else { return nil }
        self.image = image
        bleedSlices = BleedSlices(raster: raster)
        self.layout = layout
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawBleed()
        image.draw(in: scaledRect(layout.trimRect),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        drawMarks()
    }

    private func drawBleed() {
        guard layout.artworkRect != layout.trimRect, let bleedSlices else { return }
        let artworkRect = scaledRect(layout.artworkRect)
        let trimRect = scaledRect(layout.trimRect)
        let leftWidth = max(0, trimRect.minX - artworkRect.minX)
        let rightWidth = max(0, artworkRect.maxX - trimRect.maxX)
        let topHeight = max(0, trimRect.minY - artworkRect.minY)
        let bottomHeight = max(0, artworkRect.maxY - trimRect.maxY)

        bleedSlices.topLeft.draw(in: NSRect(x: artworkRect.minX, y: artworkRect.minY, width: leftWidth, height: topHeight))
        bleedSlices.top.draw(in: NSRect(x: trimRect.minX, y: artworkRect.minY, width: trimRect.width, height: topHeight))
        bleedSlices.topRight.draw(in: NSRect(x: trimRect.maxX, y: artworkRect.minY, width: rightWidth, height: topHeight))

        bleedSlices.left.draw(in: NSRect(x: artworkRect.minX, y: trimRect.minY, width: leftWidth, height: trimRect.height))
        bleedSlices.right.draw(in: NSRect(x: trimRect.maxX, y: trimRect.minY, width: rightWidth, height: trimRect.height))

        bleedSlices.bottomLeft.draw(in: NSRect(x: artworkRect.minX, y: trimRect.maxY, width: leftWidth, height: bottomHeight))
        bleedSlices.bottom.draw(in: NSRect(x: trimRect.minX, y: trimRect.maxY, width: trimRect.width, height: bottomHeight))
        bleedSlices.bottomRight.draw(in: NSRect(x: trimRect.maxX, y: trimRect.maxY, width: rightWidth, height: bottomHeight))
    }

    private func drawMarks() {
        guard !layout.cropMarks.isEmpty || !layout.registrationMarks.isEmpty else { return }
        NSColor.black.setStroke()

        let cropPath = NSBezierPath()
        cropPath.lineWidth = 0.75
        for mark in layout.cropMarks {
            cropPath.move(to: scaledPoint(mark.start))
            cropPath.line(to: scaledPoint(mark.end))
        }
        cropPath.stroke()

        for mark in layout.registrationMarks {
            let center = scaledPoint(mark.center)
            let radius = min(scaleX(mark.radius), scaleY(mark.radius))
            let circleRect = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let circle = NSBezierPath(ovalIn: circleRect)
            circle.lineWidth = 0.75
            circle.stroke()

            let crosshair = radius + min(
                scaleX(PrintLayout.registrationCrosshairExtensionMM),
                scaleY(PrintLayout.registrationCrosshairExtensionMM)
            )
            let crosshairPath = NSBezierPath()
            crosshairPath.lineWidth = 0.75
            crosshairPath.move(to: NSPoint(x: center.x - crosshair, y: center.y))
            crosshairPath.line(to: NSPoint(x: center.x + crosshair, y: center.y))
            crosshairPath.move(to: NSPoint(x: center.x, y: center.y - crosshair))
            crosshairPath.line(to: NSPoint(x: center.x, y: center.y + crosshair))
            crosshairPath.stroke()
        }
    }

    private func scaledRect(_ rect: PrintLayout.Rect) -> NSRect {
        NSRect(x: scaleX(rect.x), y: scaleY(rect.y), width: scaleX(rect.width), height: scaleY(rect.height))
    }

    private func scaledPoint(_ point: PrintLayout.Point) -> NSPoint {
        NSPoint(x: scaleX(point.x), y: scaleY(point.y))
    }

    private func scaleX(_ millimeters: Double) -> CGFloat {
        CGFloat(millimeters / layout.canvasSize.width) * bounds.width
    }

    private func scaleY(_ millimeters: Double) -> CGFloat {
        CGFloat(millimeters / layout.canvasSize.height) * bounds.height
    }
}

private struct BleedSlices {
    let topLeft: NSImage
    let top: NSImage
    let topRight: NSImage
    let left: NSImage
    let right: NSImage
    let bottomLeft: NSImage
    let bottom: NSImage
    let bottomRight: NSImage

    init?(raster: RGBAImage) {
        guard raster.width > 0, raster.height > 0 else { return nil }
        guard
            let topLeft = Self.image(from: raster, x: 0, y: 0, width: 1, height: 1),
            let top = Self.image(from: raster, x: 0, y: 0, width: raster.width, height: 1),
            let topRight = Self.image(from: raster, x: raster.width - 1, y: 0, width: 1, height: 1),
            let left = Self.image(from: raster, x: 0, y: 0, width: 1, height: raster.height),
            let right = Self.image(from: raster, x: raster.width - 1, y: 0, width: 1, height: raster.height),
            let bottomLeft = Self.image(from: raster, x: 0, y: raster.height - 1, width: 1, height: 1),
            let bottom = Self.image(from: raster, x: 0, y: raster.height - 1, width: raster.width, height: 1),
            let bottomRight = Self.image(from: raster, x: raster.width - 1, y: raster.height - 1, width: 1, height: 1)
        else {
            return nil
        }

        self.topLeft = topLeft
        self.top = top
        self.topRight = topRight
        self.left = left
        self.right = right
        self.bottomLeft = bottomLeft
        self.bottom = bottom
        self.bottomRight = bottomRight
    }

    private static func image(from raster: RGBAImage, x: Int, y: Int, width: Int, height: Int) -> NSImage? {
        guard let cgImage = ImageUtilities.makeCGImage(from: slice(raster, x: x, y: y, width: width, height: height)) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func slice(_ raster: RGBAImage, x: Int, y: Int, width: Int, height: Int) -> RGBAImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rowBytes = width * 4
        for row in 0..<height {
            let srcStart = ((y + row) * raster.width + x) * 4
            let dstStart = row * rowBytes
            rgba.replaceSubrange(dstStart..<(dstStart + rowBytes), with: raster.rgba[srcStart..<(srcStart + rowBytes)])
        }
        return RGBAImage(width: width, height: height, rgba: rgba)
    }
}
