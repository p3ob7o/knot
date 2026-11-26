import KnotUI
import SwiftUI
import Testing

@MainActor
@Suite struct ThemeTokensTests {
    @Test func theEnvironmentUsesTheDesignedTheme() {
        let theme = EnvironmentValues().knotTheme
        #expect(theme.colors[.accent] == Theme.designed.colors[.accent])
        #expect(theme.type[.playerTime] == Font.caption.monospacedDigit())
        #expect(theme.spacing.betweenSegments == Spacing.space6)
        #expect(theme.radii.regular == Radii.radiusMd)
        #expect(theme.sizes.hitTarget == 44)
        #expect(theme.motion.animation(for: .recordingPhase, reduceMotion: false) == .snappy)
    }

    @Test(arguments: ColorScheme.allCases)
    func theDesignedColoursResolve(in scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let palette = Theme.designed.colors
        for role in ColorRole.allCases {
            let color = palette[role]
            if role != .label && role != .textPrimary {
                #expect(color != .primary, "Missing colour for \(role)")
            }
            let resolved = color.resolve(in: environment)
            #expect(resolved.linearRed.isFinite && resolved.linearGreen.isFinite && resolved.linearBlue.isFinite)
            #expect((0...1).contains(resolved.opacity))
        }

        let ink: Color = scheme == .dark ? .white : .black
        let onInk: Color = scheme == .dark ? .black : .white
        #expect(palette[.accent].resolve(in: environment) == ink.resolve(in: environment))
        #expect(palette[.onAccent].resolve(in: environment) == onInk.resolve(in: environment))
        let orange: Color = scheme == .dark ? .orange : Color(red: 197.0 / 255, green: 83.0 / 255, blue: 0)
        #expect(palette[.attention].resolve(in: environment) == orange.resolve(in: environment))
        #expect(palette[.record] == .red)
        #expect(palette[.onRecord] == .white)
        #expect(palette[.toggleOn] == .green)

        let aliases: [(ColorRole, ColorRole)] = [
            (.surface, .fillTertiary), (.textPrimary, .label), (.textSecondary, .labelSecondary),
            (.pending, .labelSecondary), (.quietMark, .labelSecondary), (.failed, .attention),
            (.arrived, .accent), (.recording, .record),
        ]
        for (old, token) in aliases {
            #expect(palette[old] == palette[token])
        }
    }

    @Test func thePlaceholderKeepsItsOriginalRoles() {
        let theme = Theme.placeholder
        let colors: [ColorRole: Color] = [
            .background: .clear,
            .surface: .secondary.opacity(0.08),
            .textPrimary: .primary,
            .textSecondary: .primary.opacity(0.72),
            .accent: .accentColor,
            .recording: .red,
            .pending: .primary.opacity(0.72),
            .failed: .orange,
            .arrived: .accentColor,
            .quietMark: .primary.opacity(0.72),
            .separator: .secondary.opacity(0.3),
        ]
        for (role, color) in colors {
            #expect(theme.colors[role] == color)
        }
        let fonts: [TypeRole: Font] = [
            .noteTitle: .title2.weight(.semibold), .rowTitle: .headline, .rowPreview: .subheadline,
            .body: .body, .caption: .caption, .banner: .callout,
        ]
        for (role, font) in fonts {
            #expect(theme.type[role] == font)
        }
        #expect(theme.spacing.betweenSegments == 20)
        #expect(theme.radii.regular == 10)
    }

    @Test func theDesignedFontsAreDynamicTypeStyles() {
        #if os(macOS)
            let captureField = Font.title2
            let heading1 = Font.title.bold()
            let heading2 = Font.title2.bold()
            let stateLine = Font.subheadline
        #else
            let captureField = Font.body
            let heading1 = Font.title2.bold()
            let heading2 = Font.title3.bold()
            let stateLine = Font.footnote
        #endif
        #if os(watchOS)
            let recordingTime = Font.title2.monospacedDigit()
        #else
            let recordingTime = Font.body.monospacedDigit()
        #endif

        let expected: [TypeRole: Font] = [
            .noteTitle: .title2.bold(),
            .rowTitle: .headline,
            .rowPreview: .subheadline,
            .body: .body,
            .emphasizedBody: .body.bold(),
            .captureField: captureField,
            .markdownHeading1: heading1,
            .markdownHeading2: heading2,
            .stateLine: stateLine,
            .emphasizedStateLine: stateLine.bold(),
            .metaLine: .footnote,
            .appendCaption: stateLine,
            .playerTime: .caption.monospacedDigit(),
            .recordingTime: recordingTime,
            .outcomeTitle: .headline,
            .outcomeBody: .body,
            .outcomeDetail: stateLine,
            .notice: .callout,
            .caption: stateLine,
            .banner: .callout,
        ]
        for role in TypeRole.allCases {
            #expect(Theme.designed.type[role] == expected[role], "Unexpected text style for \(role)")
        }
    }

    #if !os(watchOS)
        @Test(arguments: ColorScheme.allCases)
        func secondaryInkReadsOnPaper(in scheme: ColorScheme) {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let palette = Theme.designed.colors
            let paper = palette[.background].resolve(in: environment)
            let ink = palette[.labelSecondary].resolve(in: environment)
            let ground = luminance(paper)
            #expect(paper.opacity == 1)
            #expect(scheme == .dark ? ground < 0.15 : ground > 0.8)

            let text = luminance(ink) * Double(ink.opacity) + ground * (1 - Double(ink.opacity))
            let ratio = (max(text, ground) + 0.05) / (min(text, ground) + 0.05)
            #expect(ratio >= 4.5)
        }

        private func luminance(_ color: Color.Resolved) -> Double {
            0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
        }
    #endif

    @Test func theMetricsMatchTheHandoff() {
        let theme = Theme.designed
        #expect(
            [
                Spacing.space1, Spacing.space2, Spacing.space3, Spacing.space4, Spacing.space5, Spacing.space6,
                Spacing.space8,
            ]
                == [4, 8, 12, 16, 20, 24, 32])
        #expect(theme.spacing.tight == Spacing.space1)
        #expect(theme.spacing.regular == Spacing.space2)
        #expect(theme.spacing.loose == Spacing.space4)
        #expect(theme.spacing.betweenSegments == Spacing.space6)
        #expect(theme.spacing.surfaceMargin == Spacing.space4)
        #expect(
            [Radii.radiusSm, Radii.radiusMd, Radii.radiusLg, Radii.radiusXl, Radii.radiusFull] == [8, 12, 20, 26, 999])
        #expect(theme.radii.small == Radii.radiusSm)
        #expect(theme.radii.regular == Radii.radiusMd)
        #expect(theme.radii.control == Radii.radiusFull)
        #expect(theme.sizes.hitTarget == 44)
        #expect(theme.sizes.hitTargetMac == 28)
        #expect(theme.sizes.recordControlWatch == 88)
        #expect(theme.sizes.readableWidth == 672)
        #expect(theme.sizes.macPanelWidth == 640)
        #expect(theme.sizes.waveformBar == 2)
    }

    @Test func theSystemSpringsRespectReduceMotion() {
        let motion = Theme.designed.motion
        for kind in MotionKind.allCases {
            #expect(motion.animation(for: kind, reduceMotion: true) == nil)
            let expected: Animation = kind == .recordingPhase ? .snappy : .smooth
            #expect(motion.animation(for: kind, reduceMotion: false) == expected)
        }
    }
}
