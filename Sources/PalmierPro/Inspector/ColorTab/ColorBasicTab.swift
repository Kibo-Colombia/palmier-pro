import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Basic color sub-tab: the looks (LUT) strip with intensity + skin-tone protection,
/// the full set of primary-correction sliders, and Auto color. Moved out of InspectorView
/// (and extended to CapCut parity) when the Color section grew sub-tabs.
struct ColorBasicTab: View {
    @Environment(EditorViewModel.self) var editor
    let clips: [Clip]

    @State private var looksVersion = 0   // bumped to refresh the strip after a .cube import
    @State private var presetsVersion = 0 // bumped after saving/deleting a grade preset

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            looksStrip
            if currentLut != nil {
                GradeSliderRow(label: "Look", clips: clips, range: 0...1, neutral: 1,
                               keyPath: \.lookIntensity, format: "%.0f", multiplier: 100, suffix: "%",
                               action: "Adjust Look Intensity")
                protectSkinToneToggle
            }

            sliderGroup(header: "Color") {
                GradeSliderRow(label: "Temperature", clips: clips, range: -100...100, neutral: 0,
                               keyPath: \.temperature, format: "%.0f", action: "Adjust Temperature")
                GradeSliderRow(label: "Tint", clips: clips, range: -100...100, neutral: 0,
                               keyPath: \.tint, format: "%.0f", action: "Adjust Tint")
                GradeSliderRow(label: "Hue", clips: clips, range: -180...180, neutral: 0,
                               keyPath: \.hue, format: "%.0f", suffix: "°", action: "Adjust Hue")
                GradeSliderRow(label: "Saturation", clips: clips, range: 0...4, neutral: 1,
                               keyPath: \.saturation, action: "Adjust Saturation")
            }

            sliderGroup(header: "Light") {
                GradeSliderRow(label: "Exposure", clips: clips, range: -4...4, neutral: 0,
                               keyPath: \.exposure, action: "Adjust Exposure")
                GradeSliderRow(label: "Brightness", clips: clips, range: -1...1, neutral: 0,
                               keyPath: \.brightness, action: "Adjust Brightness")
                GradeSliderRow(label: "Contrast", clips: clips, range: 0...4, neutral: 1,
                               keyPath: \.contrast, action: "Adjust Contrast")
                GradeSliderRow(label: "Highlights", clips: clips, range: -1...1, neutral: 0,
                               keyPath: \.highlights, action: "Adjust Highlights")
                GradeSliderRow(label: "Shadows", clips: clips, range: -1...1, neutral: 0,
                               keyPath: \.shadows, action: "Adjust Shadows")
                GradeSliderRow(label: "Fade", clips: clips, range: 0...1, neutral: 0,
                               keyPath: \.fade, action: "Adjust Fade")
            }

            sliderGroup(header: "Detail") {
                GradeSliderRow(label: "Sharpen", clips: clips, range: 0...1, neutral: 0,
                               keyPath: \.sharpen, action: "Adjust Sharpen")
                GradeSliderRow(label: "Clarity", clips: clips, range: 0...1, neutral: 0,
                               keyPath: \.clarity, action: "Adjust Clarity")
                GradeSliderRow(label: "Vignette", clips: clips, range: 0...1, neutral: 0,
                               keyPath: \.vignette, action: "Adjust Vignette")
            }

            GradeScrubHint()
            presetsStrip
            HStack(spacing: AppTheme.Spacing.sm) {
                autoColorButton
                savePresetButton
                applyToAllButton
            }
        }
    }

    // MARK: - Grade presets (user-saved)

    @ViewBuilder
    private var presetsStrip: some View {
        let presets = GradePresetStore.shared.all()
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("My presets")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(presets) { preset in
                            lookChip(name: preset.name, colors: presetSwatch(preset), selected: false) {
                                applyPreset(preset)
                            }
                            .contextMenu {
                                Button("Delete Preset", role: .destructive) {
                                    try? GradePresetStore.shared.delete(id: preset.id)
                                    presetsVersion += 1
                                }
                            }
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.xxs)
                }
            }
            .id(presetsVersion)
        }
    }

    /// Grays pushed through the preset's full grade (LUT included) — pure math, no CI render.
    private func presetSwatch(_ preset: GradePresetStore.GradePreset) -> [Color] {
        let cube = preset.grade.lut.flatMap { LUTStore.shared.cube(for: $0, resolveURL: { _ in nil }) }
        return GradeMath.swatchColors(for: preset.grade, lut: cube).map {
            Color(red: Double($0.0), green: Double($0.1), blue: Double($0.2))
        }
    }

    private func applyPreset(_ preset: GradePresetStore.GradePreset) {
        commitGradeToClips(editor, clips, actionName: "Apply Grade Preset") { c in
            editor.commitGrade(clipId: c.id) { $0 = preset.grade }
        }
    }

    private var savePresetButton: some View {
        Button {
            savePresetFromUI()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "square.and.arrow.down").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                Text("Save preset").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.white.opacity(AppTheme.Opacity.subtle)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(clips.first.map { $0.gradeAt(frame: editor.activeFrame).isIdentity } ?? true)
        .help("Save this clip's grade as a reusable preset")
    }

    private func savePresetFromUI() {
        guard let grade = clips.first.map({ $0.gradeAt(frame: editor.activeFrame) }), !grade.isIdentity else { return }
        let alert = NSAlert()
        alert.messageText = "Save Grade Preset"
        alert.informativeText = "Name this look — it will appear under My presets in every project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if (try? GradePresetStore.shared.save(name: field.stringValue, grade: grade)) != nil {
            presetsVersion += 1
        }
    }

    // MARK: - Apply to all

    private var applyToAllButton: some View {
        Button {
            applyToAllClips()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "square.on.square").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                Text("Apply to all").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.white.opacity(AppTheme.Opacity.subtle)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(clips.first.map { $0.gradeAt(frame: editor.activeFrame).isIdentity } ?? true)
        .help("Copy this clip's grade to every clip in the timeline")
    }

    /// CapCut behavior: copies the source clip's EFFECTIVE grade (at the playhead) to every
    /// gradable clip (text clips don't render a grade; adjustment layers keep their own so
    /// effects don't double up).
    private func applyToAllClips() {
        guard let grade = clips.first.map({ $0.gradeAt(frame: editor.activeFrame) }) else { return }
        let targets = editor.timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType.isVisual && $0.mediaType != .text && $0.mediaType != .adjustment
        }
        guard !targets.isEmpty else { return }
        commitGradeToClips(editor, targets, actionName: "Apply Grade to All") { c in
            editor.commitGrade(clipId: c.id) { $0 = grade }
        }
    }

    // MARK: - Slider grouping

    @ViewBuilder
    private func sliderGroup<Content: View>(header: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(header)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .padding(.top, AppTheme.Spacing.xs)
            content()
        }
    }

    // MARK: - Looks (LUT) strip

    /// The look id shared by every selected clip, or nil if they disagree / have none.
    /// Reads the effective grade — a keyframed grade carries the look in its keyframes.
    private var currentLut: String? {
        let frame = editor.activeFrame
        let first = clips.first?.gradeAt(frame: frame).lut
        return clips.allSatisfy { $0.gradeAt(frame: frame).lut == first } ? first : nil
    }

    private var looksStrip: some View {
        let frame = editor.activeFrame
        let first = clips.first?.gradeAt(frame: frame).lut
        let uniform = clips.allSatisfy { $0.gradeAt(frame: frame).lut == first }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.sm) {
                lookChip(name: "None", colors: lookSwatch(nil), selected: uniform && first == nil) {
                    applyLook(nil)
                }
                ForEach(LUTStore.shared.bundledLooks, id: \.id) { look in
                    lookChip(name: look.name, colors: lookSwatch(look.id), selected: uniform && first == look.id) {
                        applyLook(look.id)
                    }
                }
                ForEach(LUTStore.shared.importedLooks, id: \.id) { look in
                    lookChip(name: look.name, colors: lookSwatch(look.id), selected: uniform && first == look.id) {
                        applyLook(look.id)
                    }
                }
                importLookChip
            }
            .padding(.vertical, AppTheme.Spacing.xxs)
        }
        .id(looksVersion)
    }

    private func lookChip(name: String, colors: [Color], selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: AppTheme.Spacing.xxs) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .strokeBorder(
                                selected ? AppTheme.Accent.timecodeColor : Color.white.opacity(AppTheme.Opacity.muted),
                                lineWidth: selected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline)
                    )
                Text(name)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            .frame(width: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var importLookChip: some View {
        Button(action: importLookFromPanel) {
            VStack(spacing: AppTheme.Spacing.xxs) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                    .frame(width: 48, height: 32)
                    .overlay(Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .strokeBorder(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline))
                Text(".cube")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .frame(width: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Import a .cube LUT")
    }

    /// A swatch built by pushing a neutral gray ramp through the look — shows its color character.
    private func lookSwatch(_ id: String?) -> [Color] {
        guard let id, let look = BundledLooks.look(id) else {
            return [Color(white: 0.30), Color(white: 0.72)]
        }
        func c(_ v: Float) -> Color {
            let (r, g, b) = look.transform(v, v, v)
            return Color(red: Double(r), green: Double(g), blue: Double(b))
        }
        return [c(0.22), c(0.5), c(0.8)]
    }

    private func applyLook(_ id: String?) {
        commitGradeToClips(editor, clips, actionName: id == nil ? "Clear Look" : "Apply Look") { c in
            editor.commitGrade(clipId: c.id) { $0.lut = id }
        }
    }

    private func importLookFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        _ = try? LUTStore.shared.importLook(suggestedName: url.deletingPathExtension().lastPathComponent, data: data)
        looksVersion += 1
    }

    // MARK: - Protect skin tone

    private var protectSkinToneToggle: some View {
        let frame = editor.activeFrame
        let shared = sharedClipValue(clips) { $0.gradeAt(frame: frame).protectSkinTone > 0 }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Text("Protect skin tone")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Toggle("", isOn: Binding(
                get: { shared ?? false },
                set: { on in
                    commitGradeToClips(editor, clips, actionName: "Protect Skin Tone") { c in
                        editor.commitGrade(clipId: c.id) { $0.protectSkinTone = on ? 1 : 0 }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .help("Keep skin hues natural under a strong look — only affects the LUT, not your manual corrections")
    }

    // MARK: - Auto color

    private var autoColorButton: some View {
        Button {
            autoColor()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "wand.and.stars").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                Text("Auto").font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.white.opacity(AppTheme.Opacity.subtle)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Auto-correct exposure + white balance")
    }

    // TODO: GradeCompositor's temperature/tint scaling (×30 mapping, sign behavior) has known
    // issues that also skew AutoColorAnalysis's temp/tint suggestions — existing grades and
    // presets are calibrated to the current behavior, so fixing it needs a coordinated migration.
    private func autoColor() {
        let fps = editor.timeline.fps
        let items: [(String, URL)] = clips.compactMap { c in
            editor.mediaResolver.resolveURL(for: c.mediaRef).map { (c.id, $0) }
        }
        guard !items.isEmpty else { return }
        Task { @MainActor in
            var results: [(String, AutoColorAnalysis.Result)] = []
            for (id, url) in items {
                guard let clip = editor.clipFor(id: id) else { continue }
                if let r = await AutoColorAnalysis.analyze(url: url, clip: clip, fps: fps) {
                    results.append((id, r))
                }
            }
            guard !results.isEmpty else { return }
            editor.undoManager?.beginUndoGrouping()
            for (id, r) in results {
                editor.commitGrade(clipId: id) {
                    $0.exposure = r.exposure; $0.temperature = r.temperature; $0.tint = r.tint
                }
            }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Auto Color")
        }
    }
}
