import SwiftUI

struct NewTagSheet: View {
    @Binding var name: String
    @Binding var colorHex: String
    let palette: FlexokiPalette
    let onCancel: () -> Void
    let onCreate: () -> Void

    private let presetHues = FlexokiHue.allCases

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    ForEach(presetHues, id: \.self) { hue in
                        let hex = FlexokiRaw.shade(hue, 600)
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if colorHex.uppercased() == hex.uppercased() {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hue.displayName)
                    }

                    Divider()
                        .frame(height: 20)

                    ColorPicker(
                        "Custom",
                        selection: Binding(
                            get: { colorFromHex(colorHex) },
                            set: { colorHex = hexFromColor($0) }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Custom color")
                }

                if !trimmedName.isEmpty {
                    HStack {
                        let color = resolvedColor
                        Text(trimmedName)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(color)
                            .background(color.opacity(0.15), in: .capsule)
                        Spacer()
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("New Tag")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 220, idealHeight: 260)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedColor: Color {
        colorHex.isEmpty ? palette.secondary : Color(hex: colorHex)
    }

    private func colorFromHex(_ hex: String) -> Color {
        hex.isEmpty ? palette.secondary : Color(hex: hex)
    }

    private func hexFromColor(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        let r = Int(resolved.red * 255)
        let g = Int(resolved.green * 255)
        let b = Int(resolved.blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
