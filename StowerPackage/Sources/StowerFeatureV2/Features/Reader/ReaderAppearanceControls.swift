import StowerData
import SwiftUI

struct ReaderAppearanceControls: View {
    let appearance: ReaderAppearanceSettings
    let onFontSizeChanged: (Double) -> Void
    let onFontStyleChanged: (ReaderFontStyle) -> Void
    let onLineSpacingChanged: (Double) -> Void
    let onJustificationChanged: (ReaderJustification) -> Void
    let onBackgroundChanged: (ReaderBackground) -> Void
    let onPrimaryAccentChanged: (FlexokiHue) -> Void
    let onSecondaryAccentChanged: (FlexokiHue) -> Void
    let onLineWidthChanged: (Double) -> Void
    let onDone: () -> Void

    private var palette: FlexokiPalette { appearance.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Appearance")
                    .font(.headline)
                    .foregroundStyle(palette.tx)
                Spacer()
                Button("Done") { onDone() }
                    .foregroundStyle(palette.primary)
            }

            backgroundSection
            primaryAccentSection
            secondaryAccentSection

            // Plain system divider so it reads correctly over Liquid Glass.
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                controlTitle("Font Size", value: appearance.fontSize.formatted(.number.precision(.fractionLength(0))))
                Slider(
                    value: Binding(get: { appearance.fontSize }, set: { onFontSizeChanged($0) }),
                    in: ReaderAppearanceSettings.fontSizeRange
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                controlTitle("Font", value: appearance.fontStyle.displayName)
                Picker("Font", selection: Binding(get: { appearance.fontStyle }, set: { onFontStyleChanged($0) })) {
                    ForEach(ReaderFontStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .tint(palette.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                controlTitle("Line Spacing", value: appearance.lineSpacing.formatted(.number.precision(.fractionLength(1))))
                Slider(
                    value: Binding(get: { appearance.lineSpacing }, set: { onLineSpacingChanged($0) }),
                    in: ReaderAppearanceSettings.lineSpacingRange
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                controlTitle("Justification", value: appearance.justification.displayName)
                Picker("Justification", selection: Binding(get: { appearance.justification }, set: { onJustificationChanged($0) })) {
                    ForEach(ReaderJustification.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                controlTitle("Line Width", value: appearance.lineWidth.formatted(.number.precision(.fractionLength(0))))
                Slider(
                    value: Binding(get: { appearance.lineWidth }, set: { onLineWidthChanged($0) }),
                    in: ReaderAppearanceSettings.lineWidthRange
                )
            }
        }
        .padding(16)
        // No custom background — the enclosing popover already renders
        // as system Liquid Glass on iOS 26 / macOS 26. The old
        // `.background(palette.bg2)` was fighting the material.
        .tint(palette.primary)
    }

    // MARK: - Swatch sections

    @ViewBuilder private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlTitle("Background", value: appearance.background.displayName)
            HStack(spacing: 12) {
                ForEach(ReaderBackground.allCases, id: \.self) { bg in
                    BackgroundSwatch(
                        background: bg,
                        selected: appearance.background == bg,
                        ringColor: palette.primary
                    ) {
                        onBackgroundChanged(bg)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var primaryAccentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlTitle("Primary Accent", value: appearance.primaryAccent.displayName)
            AccentSwatchRow(
                selected: appearance.primaryAccent,
                background: appearance.background,
                role: .primary,
                ringColor: palette.tx,
                onSelect: onPrimaryAccentChanged
            )
        }
    }

    @ViewBuilder private var secondaryAccentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlTitle("Secondary Accent", value: appearance.secondaryAccent.displayName)
            AccentSwatchRow(
                selected: appearance.secondaryAccent,
                background: appearance.background,
                role: .secondary,
                ringColor: palette.tx,
                onSelect: onSecondaryAccentChanged
            )
        }
    }

    @ViewBuilder
    private func controlTitle(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.tx)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(palette.tx2)
        }
    }
}

// MARK: - Swatches

private struct BackgroundSwatch: View {
    let background: ReaderBackground
    let selected: Bool
    let ringColor: Color
    let action: () -> Void

    var body: some View {
        let tokens = FlexokiRaw.tokens(for: background)
        let fill = Color(hex: tokens.bg)
        let border = Color(hex: tokens.ui)
        let textTone = Color(hex: tokens.tx)

        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().strokeBorder(border, lineWidth: 1)
                    )
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(textTone)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(ringColor, lineWidth: selected ? 2.5 : 0)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(background.displayName)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }
}

private enum AccentSwatchRole { case primary, secondary }

private struct AccentSwatchRow: View {
    let selected: FlexokiHue
    let background: ReaderBackground
    let role: AccentSwatchRole
    let ringColor: Color
    let onSelect: (FlexokiHue) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(FlexokiHue.allCases, id: \.self) { hue in
                AccentSwatch(
                    hue: hue,
                    background: background,
                    selected: selected == hue,
                    ringColor: ringColor
                ) {
                    onSelect(hue)
                }
            }
        }
    }
}

private struct AccentSwatch: View {
    let hue: FlexokiHue
    let background: ReaderBackground
    let selected: Bool
    let ringColor: Color
    let action: () -> Void

    var body: some View {
        let isDark = FlexokiRaw.tokens(for: background).isDark
        let shades = FlexokiRaw.accent(hue, isDark: isDark)
        let main = Color(hex: shades.main)

        Button(action: action) {
            ZStack {
                Circle()
                    .fill(main)
                    .frame(width: 30, height: 30)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(ringColor, lineWidth: selected ? 2 : 0)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hue.displayName)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }
}
