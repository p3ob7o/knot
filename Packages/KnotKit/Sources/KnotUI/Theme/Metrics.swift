import SwiftUI

/// Spacing, in points. A note is a stack of segments separated by spacing alone
/// (docs/product-spec.md §7), so `betweenSegments` is the one gap that carries meaning.
public struct Spacing: Sendable {
    public var tight: CGFloat
    public var regular: CGFloat
    public var loose: CGFloat
    public var betweenSegments: CGFloat
    /// The margin around a surface's content.
    public var surfaceMargin: CGFloat

    public init(tight: CGFloat, regular: CGFloat, loose: CGFloat, betweenSegments: CGFloat, surfaceMargin: CGFloat) {
        self.tight = tight
        self.regular = regular
        self.loose = loose
        self.betweenSegments = betweenSegments
        self.surfaceMargin = surfaceMargin
    }

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

    public static let placeholder = Radii(small: 4, regular: 10, control: 22)
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

    public static let placeholder = Motion([
        .listChange: .easeInOut(duration: 0.2),
        .recordingPhase: .easeInOut(duration: 0.15),
        .banner: .easeOut(duration: 0.2),
    ])
}
