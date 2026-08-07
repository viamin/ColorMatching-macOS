import Foundation

/// A printable sRGB color expressed in 8-bit channels.
public struct RGBColor: Sendable, Codable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    /// Normalized channels in `0.0 ... 1.0`.
    public var normalized: (red: Double, green: Double, blue: Double) {
        (Double(red) / 255.0, Double(green) / 255.0, Double(blue) / 255.0)
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}
