import SwiftUI

/// The HSL color sub-tab: pick one of the 8 fixed hue bands, then ride that band's
/// hue shift / saturation / luminance. Values are −1…1 in the model, shown as −100…100.
struct ColorHSLTab: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    @State private var band = 0

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            bandPicker
            GradeSliderRow(label: "Hue", clips: clips, range: -1...1, neutral: 0,
                           keyPath: \.hsl.hueShift[band],
                           format: "%.0f", multiplier: 100,
                           action: "Adjust \(bandName) Hue")
            GradeSliderRow(label: "Saturation", clips: clips, range: -1...1, neutral: 0,
                           keyPath: \.hsl.saturation[band],
                           format: "%.0f", multiplier: 100,
                           action: "Adjust \(bandName) Saturation")
            GradeSliderRow(label: "Luminance", clips: clips, range: -1...1, neutral: 0,
                           keyPath: \.hsl.luminance[band],
                           format: "%.0f", multiplier: 100,
                           action: "Adjust \(bandName) Luminance")
            GradeScrubHint()
        }
    }

    private var bandName: String {
        HSLAdjust.bandNames[band].capitalized
    }

    private var bandPicker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(0..<HSLAdjust.bandCount, id: \.self) { i in
                let selected = band == i
                let touched = clips.contains { c in
                    c.grade.hsl.hueShift[i] != 0 || c.grade.hsl.saturation[i] != 0 || c.grade.hsl.luminance[i] != 0
                }
                Button {
                    band = i
                } label: {
                    ZStack {
                        Circle()
                            .fill(bandColor(i))
                            .frame(width: 18, height: 18)
                        if selected {
                            Circle()
                                .strokeBorder(AppTheme.Text.primaryColor, lineWidth: AppTheme.BorderWidth.medium)
                                .frame(width: 24, height: 24)
                        } else if touched {
                            // A subtle dot marks bands that carry a non-neutral adjustment.
                            Circle()
                                .fill(AppTheme.Text.primaryColor)
                                .frame(width: 3, height: 3)
                                .offset(y: 14)
                        }
                    }
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(bandName(i))
            }
            Spacer()
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func bandName(_ i: Int) -> String {
        HSLAdjust.bandNames[i].capitalized
    }

    private func bandColor(_ i: Int) -> Color {
        Color(hue: HSLAdjust.bandCenters[i] / 360, saturation: 0.85, brightness: 0.9)
    }
}
