import SwiftUI
import Testing

@testable import KnotUI

@MainActor
@Suite struct ThemeTokensTests {
    @Test func theEnvironmentUsesTheDesignedTheme() {
        let theme = EnvironmentValues().knotTheme
        #expect(theme.colors[.accent] == Theme.designed.colors[.accent])
        #expect(theme.type[.playerTime] == Font.caption.monospacedDigit())
        #expect(theme.spacing.betweenSegments == theme.spacing.space6)
        #expect(theme.radii.regular == theme.radii.radiusMd)
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

    #endif

    @Test(arguments: ColorScheme.allCases, ColorSchemeContrast.allCases)
    func theInksReadOnTheHandoffsReferenceGrounds(in scheme: ColorScheme, contrast: ColorSchemeContrast) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        // SwiftUI's public colorSchemeContrast accessor is read-only.
        environment._colorSchemeContrast = contrast
        #expect(environment.colorSchemeContrast == contrast)

        let secondary = AdaptiveInk.secondary.color(for: scheme, contrast: contrast).resolve(in: environment)
        let attention = AdaptiveInk.attention.color(for: scheme, contrast: contrast).resolve(in: environment)
        let palette = Theme.designed.colors
        #expect(palette[.labelSecondary].resolve(in: environment) == secondary)
        #expect(palette[.attention].resolve(in: environment) == attention)
        let dark = scheme == .dark
        let secondaryLevel = dark ? (contrast == .increased ? 0.85 : 0.72) : (contrast == .increased ? 0.25 : 0.35)
        #expect(secondary == Color(white: secondaryLevel).resolve(in: environment))
        #expect(
            palette[.accent].resolve(in: environment) == (dark ? Color.white : Color.black).resolve(in: environment))
        #expect(
            palette[.onAccent].resolve(in: environment) == (dark ? Color.black : Color.white).resolve(in: environment))
        let expectedAttention: Color = dark ? .orange : srgb(0xC55300)
        #expect(attention == expectedAttention.resolve(in: environment))

        // The handoff gives reference RGB values for each appearance, with no separate
        // Increase Contrast grounds. Composite its translucent fills in sRGB.
        let phonePaper = srgb(dark ? 0x000000 : 0xFFFFFF).resolve(in: environment)
        let phoneElevated = srgb(dark ? 0x1C1C1E : 0xFFFFFF).resolve(in: environment)
        let phoneGrouped = srgb(dark ? 0x000000 : 0xF2F2F7).resolve(in: environment)
        let macPaper = srgb(dark ? 0x1E1E1E : 0xFFFFFF).resolve(in: environment)
        let macGrouped = srgb(dark ? 0x323232 : 0xECECEC).resolve(in: environment)
        let cellFill = dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
        let noticeFill = srgb(0x767680).opacity(dark ? 0.24 : 0.12).resolve(in: environment)
        let papers = [("iPhone paper", phonePaper), ("Mac paper", macPaper)]
        let grounds =
            papers + [
                ("iPhone elevated paper and grouped cell", phoneElevated),
                ("iPhone grouped ground", phoneGrouped),
                ("Mac grouped ground", macGrouped),
                ("Mac grouped cell", composite(cellFill.resolve(in: environment), over: macGrouped, in: environment)),
                ("iPhone notice over paper", composite(noticeFill, over: phonePaper, in: environment)),
                ("iPhone notice over elevated paper", composite(noticeFill, over: phoneElevated, in: environment)),
                ("iPhone notice over grouped ground", composite(noticeFill, over: phoneGrouped, in: environment)),
                ("Mac notice over paper", composite(noticeFill, over: macPaper, in: environment)),
                ("Mac notice over grouped ground", composite(noticeFill, over: macGrouped, in: environment)),
            ]
        for (name, ground) in grounds {
            let ratio = contrastRatio(secondary, on: ground, in: environment)
            #expect(ratio >= 4.5, "Secondary ink on \(name)")
        }
        for (name, paper) in papers {
            let ratio = contrastRatio(attention, on: paper, in: environment)
            #expect(ratio >= 4.5, "Attention on \(name)")
        }
    }

    private func srgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB, red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    private func composite(_ front: Color.Resolved, over back: Color.Resolved, in environment: EnvironmentValues)
        -> Color.Resolved
    {
        let alpha = front.opacity
        func blend(_ foreground: Float, _ background: Float) -> Double {
            Double(foreground * alpha + background * (1 - alpha))
        }
        return Color(
            .sRGB, red: blend(front.red, back.red), green: blend(front.green, back.green),
            blue: blend(front.blue, back.blue)
        ).resolve(in: environment)
    }

    private func contrastRatio(
        _ foreground: Color.Resolved, on ground: Color.Resolved, in environment: EnvironmentValues
    )
        -> Double
    {
        let ink = luminance(composite(foreground, over: ground, in: environment))
        let paper = luminance(ground)
        return (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
    }

    private func luminance(_ color: Color.Resolved) -> Double {
        0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
    }

    @Test func theMetricsMatchTheHandoff() {
        let theme = Theme.designed
        #expect(
            [
                theme.spacing.space1, theme.spacing.space2, theme.spacing.space3, theme.spacing.space4,
                theme.spacing.space5, theme.spacing.space6,
                theme.spacing.space8,
            ]
                == [4, 8, 12, 16, 20, 24, 32])
        #expect(theme.spacing.tight == theme.spacing.space1)
        #expect(theme.spacing.regular == theme.spacing.space2)
        #expect(theme.spacing.loose == theme.spacing.space4)
        #expect(theme.spacing.betweenSegments == theme.spacing.space6)
        #expect(theme.spacing.surfaceMargin == theme.spacing.space4)
        #expect(
            [
                theme.radii.radiusSm, theme.radii.radiusMd, theme.radii.radiusLg, theme.radii.radiusXl,
                theme.radii.radiusFull,
            ] == [8, 12, 20, 26, 999])
        #expect(theme.radii.small == theme.radii.radiusSm)
        #expect(theme.radii.regular == theme.radii.radiusMd)
        #expect(theme.radii.control == theme.radii.radiusFull)
        #expect(theme.sizes.hitTarget == 44)
        #expect(theme.sizes.hitTargetMac == 28)
        #expect(theme.sizes.recordControlWatch == 88)
        #expect(theme.sizes.readableWidth == 672)
        #expect(theme.sizes.macPanelWidth == 640)
        #expect(theme.sizes.waveformBar == 2)
    }

    @Test func theEnvironmentCarriesCustomMetrics() {
        var custom = Theme(
            colors: .placeholder,
            type: .placeholder,
            spacing: Spacing(tight: 1, regular: 2, loose: 3, betweenSegments: 4, surfaceMargin: 5),
            radii: Radii(small: 1, regular: 2, control: 3),
            motion: .placeholder)
        custom.spacing.space3 = 15
        custom.radii.radiusLg = 21
        custom.sizes = Sizes(hitTarget: 52, waveformBar: 3)
        var environment = EnvironmentValues()
        environment.knotTheme = custom

        let theme = environment.knotTheme
        #expect(theme.spacing.space3 == 15)
        #expect(theme.spacing.betweenSegments == 4)
        #expect(theme.radii.radiusLg == 21)
        #expect(theme.radii.control == 3)
        #expect(theme.sizes.hitTarget == 52)
        #expect(theme.sizes.waveformBar == 3)
        #expect(theme.sizes.hitTargetMac == 28)
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
