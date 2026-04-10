import SwiftUI

struct ReaderAppearanceControls: View {
    let appearance: ReaderAppearanceSettings
    let onFontSizeChanged: (Double) -> Void
    let onFontStyleChanged: (ReaderFontStyle) -> Void
    let onLineSpacingChanged: (Double) -> Void
    let onJustificationChanged: (ReaderJustification) -> Void
    let onThemeChanged: (ReaderTheme) -> Void
    let onLineWidthChanged: (Double) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Appearance")
                    .font(.headline)
                    .foregroundStyle(appearance.primaryTextColor)
                Spacer()
                Button("Done") { onDone() }
            }

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
                controlTitle("Theme", value: appearance.theme.displayName)
                Picker("Theme", selection: Binding(get: { appearance.theme }, set: { onThemeChanged($0) })) {
                    ForEach(ReaderTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
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
        .padding(14)
        .background(appearance.surfaceColor, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func controlTitle(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
        }
        .foregroundStyle(appearance.secondaryTextColor)
    }
}
