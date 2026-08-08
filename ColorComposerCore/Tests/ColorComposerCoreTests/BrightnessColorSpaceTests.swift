import XCTest
@testable import ColorComposerCore

final class BrightnessColorSpaceTests: XCTestCase {

    // MARK: - Gamma mode (the default)

    func testGammaDecodeIsIdentity() {
        for v in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(BrightnessColorSpace.gamma.decode(v), v, accuracy: 1e-12)
        }
    }

    func testDefaultIsGammaToMatchServer() {
        XCTAssertEqual(BrightnessColorSpace(rawValue: "gamma"), .gamma)
        // The first case is the conventional default.
        XCTAssertEqual(BrightnessColorSpace.allCases.first, .gamma)
    }

    // MARK: - Linear mode

    func testLinearDecodeEndpointsAreZeroAndOne() {
        XCTAssertEqual(BrightnessColorSpace.linear.decode(0.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(BrightnessColorSpace.linear.decode(1.0), 1.0, accuracy: 1e-12)
    }

    func testLinearDecodeMatchesStaticTransferFunction() {
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(
                BrightnessColorSpace.linear.decode(v),
                BrightnessColorSpace.gammaToLinear(v),
                accuracy: 1e-12
            )
        }
    }

    func testLinearDecodeKnownSRGBValues() {
        // Reference linear-luminance values for canonical sRGB (gamma) inputs,
        // from the standard transfer function pow((v + 0.055) / 1.055, 2.4).
        XCTAssertEqual(BrightnessColorSpace.gammaToLinear(0.25), 0.05087608817155679, accuracy: 1e-9)
        XCTAssertEqual(BrightnessColorSpace.gammaToLinear(0.50), 0.21404114048223243, accuracy: 1e-9)
        XCTAssertEqual(BrightnessColorSpace.gammaToLinear(0.75), 0.5225215539683921, accuracy: 1e-9)
    }

    func testLinearDecodeDarkValueUsesLinearSegment() {
        // Below the sRGB breakpoint the transfer function is linear: v / 12.92.
        XCTAssertEqual(BrightnessColorSpace.gammaToLinear(0.04045), 0.04045 / 12.92, accuracy: 1e-12)
    }

    func testLinearDecodeIsAlwaysBelowGammaForMidtones() {
        // Decoding to linear dims midtones relative to gamma space.
        XCTAssertLessThan(BrightnessColorSpace.linear.decode(0.5), 0.5)
        XCTAssertGreaterThan(BrightnessColorSpace.linear.decode(0.5), 0.0)
    }

    func testCodableRoundTrip() {
        for mode in BrightnessColorSpace.allCases {
            let data = try! JSONEncoder().encode(mode)
            let restored = try! JSONDecoder().decode(BrightnessColorSpace.self, from: data)
            XCTAssertEqual(restored, mode)
        }
    }
}

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Integration coverage for `BrightnessGridSampler` end-to-end sampling in both
/// color spaces. Excluded from the portable Foundation build (Linux CI) since it
/// requires Apple frameworks; runs on macOS where Core Graphics is available.
final class BrightnessGridSamplerColorSpaceTests: XCTestCase {

    private func solidGrayImage(_ gray: UInt8) -> CGImage {
        var bytes = [UInt8](repeating: gray, count: 1)
        let cs = CGColorSpaceCreateDeviceGray()
        let provider = CGDataProvider(data: Data(bytes: &bytes, count: bytes.count) as CFData)!
        return CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 1, space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testGammaSamplingMatchesValueOver255() {
        let image = solidGrayImage(128)
        let grid = BrightnessGridSampler.sample(
            cgImage: image, targetWidth: 1, targetHeight: 1, scalingMode: .stretch
        )
        XCTAssertEqual(grid.value(x: 0, y: 0), 128.0 / 255.0, accuracy: 1e-9)
    }

    func testLinearSamplingMatchesGammaToLinear() {
        let image = solidGrayImage(128)
        let grid = BrightnessGridSampler.sample(
            cgImage: image, targetWidth: 1, targetHeight: 1, scalingMode: .stretch,
            colorSpace: .linear
        )
        XCTAssertEqual(
            grid.value(x: 0, y: 0),
            BrightnessColorSpace.gammaToLinear(128.0 / 255.0),
            accuracy: 1e-3
        )
    }

    func testDefaultColorSpaceIsGamma() {
        let image = solidGrayImage(200)
        let explicit = BrightnessGridSampler.sample(
            cgImage: image, targetWidth: 1, targetHeight: 1, scalingMode: .stretch,
            colorSpace: .gamma
        )
        let defaulted = BrightnessGridSampler.sample(
            cgImage: image, targetWidth: 1, targetHeight: 1, scalingMode: .stretch
        )
        XCTAssertEqual(explicit.value(x: 0, y: 0), defaulted.value(x: 0, y: 0), accuracy: 1e-12)
    }
}
#endif
