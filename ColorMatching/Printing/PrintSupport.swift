import AppKit

/// Native macOS printing for a composited image, using `NSPrintOperation`.
///
/// The image is embedded in a trivial `NSView` whose bounds match the intended
/// physical print size, so the print dialog honors the artwork's dimensions and
/// the user can scale via standard printer-driver options.
enum PrintSupport {

    /// Presents the native print dialog for `image` at a given physical size.
    static func print(_ image: NSImage, physicalSizeMM: CGSize, title: String = "ColorMatching") {
        let view = PrintableImageView(image: image)

        // Points (1 pt = 1/72 inch; 1 inch = 25.4 mm).
        let pointsPerMM = 72.0 / 25.4
        view.frame = NSRect(
            x: 0, y: 0,
            width: physicalSizeMM.width * pointsPerMM,
            height: physicalSizeMM.height * pointsPerMM
        )

        let printInfo = NSPrintInfo.shared
        // Keep reasonable default margins; the user can still adjust in the panel.
        printInfo.leftMargin = max(printInfo.leftMargin, 18)
        printInfo.rightMargin = max(printInfo.rightMargin, 18)
        printInfo.topMargin = max(printInfo.topMargin, 18)
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
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds,
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
    }
}
