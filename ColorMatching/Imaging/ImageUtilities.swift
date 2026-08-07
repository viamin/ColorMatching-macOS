import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ColorComposerCore

/// Helpers bridging the core package's data types and AppKit/CoreGraphics image
/// representations, plus native image export via ImageIO.
enum ImageUtilities {

    /// Loads an image from disk, returning the raw data, a display name, and a
    /// `CGImage`. Supports PNG, JPEG, TIFF, and HEIC where natively readable.
    static func load(from url: URL) throws -> (data: Data, filename: String, cgImage: CGImage) {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadError.unreadable
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoadError.unreadable
        }
        return (data, url.lastPathComponent, cgImage)
    }

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Builds an `NSImage` from the core package's RGBA buffer.
    static func nsImage(from rgba: RGBAImage) -> NSImage? {
        guard let cgImage = makeCGImage(from: rgba) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: rgba.width, height: rgba.height))
    }

    static func makeCGImage(from rgba: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba.rgba) as CFData) else { return nil }
        return CGImage(
            width: rgba.width,
            height: rgba.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rgba.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Renders a grayscale brightness grid to a grayscale `CGImage` for previews.
    static func makeGrayscaleCGImage(from grid: BrightnessGrid) -> CGImage? {
        let bytes = grid.values.map { UInt8(min(max($0, 0), 1) * 255.0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: grid.width,
            height: grid.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: grid.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [],
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func nsImage(from grid: BrightnessGrid) -> NSImage? {
        guard let cgImage = makeGrayscaleCGImage(from: grid) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: grid.width, height: grid.height))
    }

    /// Writes an image to disk using ImageIO. Format is inferred from the URL's
    /// extension (PNG, TIFF, JPEG).
    static func write(_ image: CGImage, to url: URL) throws {
        let typeID: CFString
        switch url.pathExtension.lowercased() {
        case "tif", "tiff": typeID = UTType.tiff.identifier as CFString
        case "jpg", "jpeg": typeID = UTType.jpeg.identifier as CFString
        default: typeID = UTType.png.identifier as CFString
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, typeID, 1, nil) else {
            throw ImageWriteError.unsupportedFormat
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageWriteError.writeFailed
        }
    }
}

enum ImageLoadError: Error, LocalizedError {
    case unreadable
    var errorDescription: String? { "The selected file could not be read as an image." }
}

enum ImageWriteError: Error, LocalizedError {
    case unsupportedFormat
    case writeFailed
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Unsupported image format. Use PNG, TIFF, or JPEG."
        case .writeFailed: return "The image could not be written."
        }
    }
}
