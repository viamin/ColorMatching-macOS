import Foundation

// MARK: - DTOs (wire format from `color_matching` /api/v1)

/// Wire representation of a printer/material profile.
public struct PrinterProfileDTO: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let printerMakeModel: String?
    public let paperType: String?
    public let inkType: String?
}

/// Wire representation of a palette summary.
public struct PaletteSummaryDTO: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let isPreset: Bool
    public let colorCount: Int
}

/// Wire representation of one measured illuminant response.
public struct ColorResponseDTO: Codable, Sendable, Equatable {
    public let brightness: Double
    public let source: String?
    public let rawValue: Double?
    public let rawUnit: String?
    public let apparentBrightness: Int?
    public let measuredAt: String?
    public let testRunId: String?
}

public struct RGBDTO: Codable, Sendable, Equatable {
    public let r: Int
    public let g: Int
    public let b: Int
}

/// Wire representation of a palette color with its response vector.
public struct PaletteColorDTO: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String?
    public let hex: String
    public let rgb: RGBDTO?
    public let paletteId: Int?
    public let paletteName: String?
    public let sortOrder: Int?
    public let responses: [String: ColorResponseDTO]
}

// MARK: - Response envelopes

struct ColorsResponse: Codable {
    let colors: [PaletteColorDTO]
    let printerProfile: PrinterProfileDTO?
}

struct PalettesResponse: Codable {
    let palettes: [PaletteSummaryDTO]
}

struct PrinterProfilesResponse: Codable {
    let printerProfiles: [PrinterProfileDTO]
}

// MARK: - Domain conversion

public extension PaletteColorDTO {
    /// Converts the wire DTO into the solver's domain model. Unknown light-source
    /// keys in `responses` are ignored; only canonical conditions are kept.
    func toDomain() -> PaletteColor? {
        let resolvedRGB: RGBColor
        if let dto = rgb {
            resolvedRGB = RGBColor(red: UInt8(clamping: dto.r), green: UInt8(clamping: dto.g), blue: UInt8(clamping: dto.b))
        } else {
            guard let parsed = RGBColor(hex: hex) else { return nil }
            resolvedRGB = parsed
        }
        var domainResponses: [LightingCondition: IlluminationResponse] = [:]
        for (key, responseDTO) in responses {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            domainResponses[condition] = IlluminationResponse(
                brightness: responseDTO.brightness,
                source: responseDTO.source,
                apparentBrightness: responseDTO.apparentBrightness,
                rawValue: responseDTO.rawValue,
                rawUnit: responseDTO.rawUnit
            )
        }

        return PaletteColor(
            id: id,
            name: name,
            hex: hex,
            rgb: resolvedRGB,
            paletteID: paletteId,
            paletteName: paletteName,
            sortOrder: sortOrder,
            responses: domainResponses
        )
    }
}
