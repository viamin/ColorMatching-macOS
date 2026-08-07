import XCTest
@testable import ColorComposerCore

final class RGBColorTests: XCTestCase {
    func testHexParsingSixDigits() {
        let c = RGBColor(hex: "#C64A35")!
        XCTAssertEqual(c.red, 198)
        XCTAssertEqual(c.green, 74)
        XCTAssertEqual(c.blue, 53)
        XCTAssertEqual(c.hexString, "#C64A35")
    }

    func testHexParsingWithoutHash() {
        let c = RGBColor(hex: "FFFFFF")!
        XCTAssertEqual(c.red, 255)
        XCTAssertEqual(c.green, 255)
        XCTAssertEqual(c.blue, 255)
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(RGBColor(hex: "nope"))
        XCTAssertNil(RGBColor(hex: "#12345"))
    }

    func testNormalized() {
        let n = RGBColor(red: 255, green: 0, blue: 128).normalized
        XCTAssertEqual(n.red, 1.0, accuracy: 1e-9)
        XCTAssertEqual(n.green, 0.0, accuracy: 1e-9)
        XCTAssertEqual(n.blue, 128.0 / 255.0, accuracy: 1e-9)
    }
}
