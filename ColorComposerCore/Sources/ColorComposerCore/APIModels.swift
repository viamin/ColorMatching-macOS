import Foundation

// MARK: - DTOs (wire format from `color_matching` /api/v1)

/// Wire representation of a printer/material profile.
public struct PrinterProfileDTO: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let printerMakeModel: String?
    public let paperType: String?
    public let inkType: String?
}

public extension PrinterProfileDTO {
    var displayName: String {
        let parts = [printerMakeModel, paperType, inkType].compactMap { normalizedLabelPart($0) }
        return parts.isEmpty ? "Profile #\(id)" : parts.joined(separator: " · ")
    }

    var softProofProfile: SoftProofProfile {
        var profile = SoftProofProfile.genericPrinter
        let paper = normalizedSearchText(paperType)
        let ink = normalizedSearchText(inkType)

        if matchesAny(paper, ["matte", "rag", "fine art", "watercolor", "etch"]) {
            profile = SoftProofProfile(
                paperWhite: RGBColor(red: 242, green: 236, blue: 226),
                paperBlend: 0.12,
                blackFloor: 0.05,
                contrastScale: 0.84,
                baseChromaLimit: 0.70,
                midtoneChromaPenalty: 0.32,
                shadowChromaPenalty: 0.24,
                warningOverlayOpacity: 0.40
            )
        } else if matchesAny(paper, ["gloss", "glossy", "luster", "lustre", "satin", "semi-gloss", "baryta"]) {
            profile = SoftProofProfile(
                paperWhite: RGBColor(red: 249, green: 247, blue: 241),
                paperBlend: 0.05,
                blackFloor: 0.02,
                contrastScale: 0.94,
                baseChromaLimit: 0.84,
                midtoneChromaPenalty: 0.22,
                shadowChromaPenalty: 0.14,
                warningOverlayOpacity: 0.30
            )
        }

        if matchesAny(ink, ["pigment"]) {
            profile = SoftProofProfile(
                paperWhite: profile.paperWhite,
                paperBlend: profile.paperBlend,
                blackFloor: SoftProofing.clamp(profile.blackFloor - 0.01),
                contrastScale: SoftProofing.clamp(profile.contrastScale + 0.02),
                baseChromaLimit: SoftProofing.clamp(profile.baseChromaLimit + 0.02),
                midtoneChromaPenalty: profile.midtoneChromaPenalty,
                shadowChromaPenalty: profile.shadowChromaPenalty,
                warningOverlayOpacity: SoftProofing.clamp(profile.warningOverlayOpacity - 0.03)
            )
        } else if matchesAny(ink, ["dye"]) {
            profile = SoftProofProfile(
                paperWhite: profile.paperWhite,
                paperBlend: SoftProofing.clamp(profile.paperBlend + 0.01),
                blackFloor: profile.blackFloor,
                contrastScale: SoftProofing.clamp(profile.contrastScale - 0.02),
                baseChromaLimit: SoftProofing.clamp(profile.baseChromaLimit + 0.01),
                midtoneChromaPenalty: profile.midtoneChromaPenalty,
                shadowChromaPenalty: profile.shadowChromaPenalty,
                warningOverlayOpacity: SoftProofing.clamp(profile.warningOverlayOpacity + 0.02)
            )
        }

        return profile
    }

    private func normalizedLabelPart(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedSearchText(_ value: String?) -> String {
        normalizedLabelPart(value)?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) ?? ""
    }

    private func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
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
