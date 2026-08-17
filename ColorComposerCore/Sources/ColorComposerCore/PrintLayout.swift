import Foundation

public struct PrintOverlayOptions: Sendable, Equatable, Codable {
    public var showsMarks: Bool
    public var markInsetMM: Double
    public var bleedMM: Double

    public init(
        showsMarks: Bool = false,
        markInsetMM: Double = 3.0,
        bleedMM: Double = 0.0
    ) {
        self.showsMarks = showsMarks
        self.markInsetMM = markInsetMM
        self.bleedMM = bleedMM
    }
}

public struct PrintLayout: Sendable, Equatable {
    public static let registrationCrosshairExtensionMM = 2.0

    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Size: Sendable, Equatable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Rect: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var minX: Double { x }
        public var maxX: Double { x + width }
        public var midX: Double { x + (width / 2) }
        public var minY: Double { y }
        public var maxY: Double { y + height }
        public var midY: Double { y + (height / 2) }

        public func expanded(by amount: Double) -> Rect {
            Rect(x: x - amount, y: y - amount, width: width + (amount * 2), height: height + (amount * 2))
        }
    }

    public struct Line: Sendable, Equatable {
        public let start: Point
        public let end: Point

        public init(start: Point, end: Point) {
            self.start = start
            self.end = end
        }
    }

    public struct RegistrationMark: Sendable, Equatable {
        public let center: Point
        public let radius: Double

        public init(center: Point, radius: Double) {
            self.center = center
            self.radius = radius
        }
    }

    public let canvasSize: Size
    public let trimRect: Rect
    public let artworkRect: Rect
    public let cropMarks: [Line]
    public let registrationMarks: [RegistrationMark]

    public static func make(
        physicalSizeMM: Size,
        options: PrintOverlayOptions,
        markLengthMM: Double = 6.0,
        registrationRadiusMM: Double = 3.0
    ) -> PrintLayout {
        let trimSize = Size(
            width: sanitizedMeasurement(physicalSizeMM.width),
            height: sanitizedMeasurement(physicalSizeMM.height)
        )
        let bleed = sanitizedMeasurement(options.bleedMM)
        let markInset = sanitizedMeasurement(options.markInsetMM)
        let markLength = sanitizedMeasurement(markLengthMM)
        let registrationRadius = sanitizedMeasurement(registrationRadiusMM)
        let outerPadding = showsMarksPadding(
            showsMarks: options.showsMarks,
            bleed: bleed,
            markInset: markInset,
            markLength: markLength,
            registrationRadius: registrationRadius
        )

        let trimRect = Rect(
            x: outerPadding,
            y: outerPadding,
            width: trimSize.width,
            height: trimSize.height
        )
        let artworkRect = trimRect.expanded(by: bleed)

        return PrintLayout(
            canvasSize: Size(
                width: trimSize.width + (outerPadding * 2),
                height: trimSize.height + (outerPadding * 2)
            ),
            trimRect: trimRect,
            artworkRect: artworkRect,
            cropMarks: cropMarks(for: trimRect, inset: markInset, length: markLength, enabled: options.showsMarks),
            registrationMarks: registrationMarks(
                for: trimRect,
                inset: markInset,
                radius: registrationRadius,
                enabled: options.showsMarks
            )
        )
    }

    private static func sanitizedMeasurement(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func showsMarksPadding(
        showsMarks: Bool,
        bleed: Double,
        markInset: Double,
        markLength: Double,
        registrationRadius: Double
    ) -> Double {
        guard showsMarks else { return bleed }
        return bleed + markInset + max(markLength, registrationMarkExtent(radius: registrationRadius))
    }

    private static func registrationMarkExtent(radius: Double) -> Double {
        (radius * 2) + registrationCrosshairExtensionMM
    }

    private static func cropMarks(for rect: Rect, inset: Double, length: Double, enabled: Bool) -> [Line] {
        guard enabled else { return [] }
        let top = rect.minY - inset
        let bottom = rect.maxY + inset
        let left = rect.minX - inset
        let right = rect.maxX + inset

        return [
            Line(start: Point(x: rect.minX, y: top - length), end: Point(x: rect.minX, y: top)),
            Line(start: Point(x: rect.maxX, y: top - length), end: Point(x: rect.maxX, y: top)),
            Line(start: Point(x: rect.minX, y: bottom), end: Point(x: rect.minX, y: bottom + length)),
            Line(start: Point(x: rect.maxX, y: bottom), end: Point(x: rect.maxX, y: bottom + length)),
            Line(start: Point(x: left - length, y: rect.minY), end: Point(x: left, y: rect.minY)),
            Line(start: Point(x: right, y: rect.minY), end: Point(x: right + length, y: rect.minY)),
            Line(start: Point(x: left - length, y: rect.maxY), end: Point(x: left, y: rect.maxY)),
            Line(start: Point(x: right, y: rect.maxY), end: Point(x: right + length, y: rect.maxY))
        ]
    }

    private static func registrationMarks(
        for rect: Rect,
        inset: Double,
        radius: Double,
        enabled: Bool
    ) -> [RegistrationMark] {
        guard enabled else { return [] }
        let offset = inset + radius
        return [
            RegistrationMark(center: Point(x: rect.midX, y: rect.minY - offset), radius: radius),
            RegistrationMark(center: Point(x: rect.midX, y: rect.maxY + offset), radius: radius),
            RegistrationMark(center: Point(x: rect.minX - offset, y: rect.midY), radius: radius),
            RegistrationMark(center: Point(x: rect.maxX + offset, y: rect.midY), radius: radius)
        ]
    }
}
