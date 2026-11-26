import SwiftUI

/// Spacing, in points. A note is a stack of segments separated by spacing alone
/// (docs/product-spec.md §7), so `betweenSegments` is the one gap that carries meaning.
public struct Spacing: Sendable {
    public var tight: CGFloat
    public var regular: CGFloat
    public var loose: CGFloat
    public var betweenSegments: CGFloat
    /// Compact margin fallback. Use the system layout margin when it is available.
    public var surfaceMargin: CGFloat

    public init(tight: CGFloat, regular: CGFloat, loose: CGFloat, betweenSegments: CGFloat, surfaceMargin: CGFloat) {
        self.tight = tight
        self.regular = regular
        self.loose = loose
        self.betweenSegments = betweenSegments
        self.surfaceMargin = surfaceMargin
    }

    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    /// Compact layout margin fallback. Prefer the safe area and system content margins.
    public static let space4: CGFloat = 16
    /// Regular layout margin fallback. Also the Mac capture panel's inner padding.
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24
    public static let space8: CGFloat = 32

    public static let designed = Spacing(
        tight: space1, regular: space2, loose: space4, betweenSegments: space6, surfaceMargin: space4)

    public static let placeholder = Spacing(tight: 4, regular: 8, loose: 16, betweenSegments: 20, surfaceMargin: 16)
}

/// Corner radii, in points.
public struct Radii: Sendable {
    public var small: CGFloat
    public var regular: CGFloat
    public var control: CGFloat

    public init(small: CGFloat, regular: CGFloat, control: CGFloat) {
        self.small = small
        self.regular = regular
        self.control = control
    }

    public static let radiusSm: CGFloat = 8
    public static let radiusMd: CGFloat = 12
    public static let radiusLg: CGFloat = 20
    public static let radiusXl: CGFloat = 26
    /// The capsule token's numeric value. Prefer the system capsule shape.
    public static let radiusFull: CGFloat = 999

    public static let designed = Radii(small: radiusSm, regular: radiusMd, control: radiusFull)

    public static let placeholder = Radii(small: 4, regular: 10, control: 22)
}

/// Control and layout sizes, in points.
public struct Sizes: Sendable {
    public let hitTarget: CGFloat = 44
    public let hitTargetMac: CGFloat = 28
    public let recordControlWatch: CGFloat = 88
    /// Fallback at the default text size. Prefer the system's scalable readable width.
    public let readableWidth: CGFloat = 672
    public let macPanelWidth: CGFloat = 640
    public let waveformBar: CGFloat = 2
}

/// What moves. Each kind has an animation, and Reduce Motion turns every one of them off
/// (docs/product-spec.md §13): `animation(for:reduceMotion:)` is the only way a view gets one.
public enum MotionKind: String, Hashable, Sendable, CaseIterable {
    /// A row or a segment appears or leaves.
    case listChange
    /// The record button changes phase.
    case recordingPhase
    /// A banner appears or leaves.
    case banner
}

public struct Motion: Sendable {
    private var animations: [MotionKind: Animation]

    public init(_ animations: [MotionKind: Animation]) {
        self.animations = animations
    }

    /// The animation for `kind`, or `nil` when Reduce Motion is on.
    public func animation(for kind: MotionKind, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animations[kind] ?? .default
    }

    public static let designed = Motion([
        .listChange: .smooth,
        .recordingPhase: .snappy,
        .banner: .smooth,
    ])

    public static let placeholder = Motion([
        .listChange: .easeInOut(duration: 0.2),
        .recordingPhase: .easeInOut(duration: 0.15),
        .banner: .easeOut(duration: 0.2),
    ])
}
