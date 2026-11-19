import SwiftUI

/// The card editor: a pinned preview, then Presets and three panels of controls that take turns under it, so each panel
/// fits on about one screen and every change shows in the preview as it's made.
struct AppearanceView: View {
    enum Panel: String, CaseIterable { case presets = "Presets", layout = "Layout", text = "Text", colour = "Colour" }

    let engine: LyricsEngine
    @State private var style = CardStyle.saved
    @State private var carPlay = false
    @State private var confirmReset = false
    @State private var opened = false
    /// Looks replaced by a preset tap or a shuffle, newest last, for "Previous look".
    @State private var previous: [CardStyle] = []
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: UserPreset?
    @SceneStorage("appearancePanel") private var panel = Panel.presets
    /// The look last applied (a preset or one of yours), for "Sunset · edited", Revert and Save.
    @AppStorage("presetBase") private var presetBase = ""
    /// An unsaved custom look, kept whenever the style matches no look, so applying another never loses it.
    @AppStorage("customStyle") private var customStyle: Data?
    @AppStorage("customBase") private var customBase = ""
    /// Your own named looks ("Make your own").
    @AppStorage("userPresets") private var userPresets: Data?
    @Environment(\.self) private var environment

    private enum Naming: Equatable {
        case new(thenEdit: Bool), rename(UserPreset)

        var title: String {
            switch self {
            case .new: "Name your look"
            case .rename: "Rename look"
            }
        }
    }

    private var mine: [UserPreset] { UserPreset.list(userPresets) }

    /// True when the style matches no preset and none of your looks.
    private func isCustom(_ style: CardStyle) -> Bool {
        CardPreset.matching(style) == nil && !mine.contains { $0.style == style.withoutCounter }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                preview
                HStack {
                    Picker("Preview", selection: $carPlay) {
                        Text("Lock Screen").tag(false)
                        Text("CarPlay").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    seeItLive
                }
                if let note = previewNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 16) {
                    Text(CardPreset.lookName(style, base: presetBase, mine: mine)).fontWeight(.semibold)
                    Spacer()
                    if isCustom(style) {
                        if let base = CardPreset.named(presetBase)?.style ?? mine.first(where: { $0.name == presetBase })?.style {
                            Button("Revert") { apply(base, base: presetBase) }
                        }
                        if let own = mine.first(where: { $0.name == presetBase }) {
                            Button("Save") { update(own) }.fontWeight(.semibold)
                        } else {
                            Button("Save as new") { startNaming(.new(thenEdit: false)) }.fontWeight(.semibold)
                        }
                    }
                }
                .font(.subheadline)
                Picker("Panel", selection: $panel) {
                    ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)
            Form {
                switch panel {
                case .presets: presets
                case .layout: layout
                case .text: text
                case .colour: colours
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                ForEach(CardStyle.Shuffle.allCases, id: \.self) { what in
                    Button(what.title, systemImage: what.symbol) { shuffle(what) }
                }
                Divider()
                Button("Previous look", systemImage: "arrow.uturn.backward") { style = previous.removeLast() }
                    .disabled(previous.isEmpty)
            } label: {
                Label("Shuffle", systemImage: "dice")
            }
            Menu {
                Button("Reset to Midnight", role: .destructive) { confirmReset = true }
                    .disabled(style.withoutCounter == CardStyle())
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        .confirmationDialog("Reset to Midnight?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to Midnight", role: .destructive) { apply(CardStyle(), base: "Midnight") }
        } message: {
            Text("You can get your current look back from Presets.")
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
               presenting: naming) { kind in
            TextField("Name", text: $name)
            Button("Save") { commitName(kind) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            if case .new = kind { Text("Saves the look you have now. Change anything, then tap Save to keep it.") }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this look")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { look in
            Button("Delete", role: .destructive) { delete(look) }
        } message: { _ in
            Text("The card keeps its current look.")
        }
        .onAppear {
            guard !opened else { return }  // not again on coming back from the font list
            opened = true
            if CardPreset.matching(style) != nil { panel = .presets }
            #if DEBUG
            if let debugPanel = UserDefaults.standard.string(forKey: "panel").flatMap(Panel.init) { panel = debugPanel }
            if UserDefaults.standard.bool(forKey: "shuffle") { shuffle(.everything) }  // -shuffle YES, for screenshots
            #endif
        }
        // Waits for a pause so dragging a slider or colour wheel doesn't flood the card with updates.
        .task(id: style) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear { save() }  // leaving within 400 ms of a change still keeps it
    }

    // MARK: Preview

    private var preview: some View {
        // Redrawn every 4 s so the preview's progress bar keeps looping.
        TimelineView(.periodic(from: .now, by: 4)) { _ in
            if carPlay {
                LyricsCard(state: .sample(style), small: true).frame(width: 240, height: 110).clipShape(.rect(cornerRadius: 14))
            } else {
                LyricsCard(state: .sample(style)).frame(height: 150).clipShape(.rect(cornerRadius: 22))
            }
        }
        .frame(height: 150)
    }

    /// Runs the demo song so the real card shows on the Lock Screen and CarPlay, which the preview can only approximate.
    @ViewBuilder private var seeItLive: some View {
        switch engine.running {
        case nil:
            Button("See it live", systemImage: "play.circle") { Task { await engine.start(.demo) } }
                .font(.subheadline.weight(.semibold))
        case .demo:
            Label("Demo on", systemImage: "dot.radiowaves.left.and.right").font(.subheadline).foregroundStyle(.green)
        default:
            EmptyView()
        }
    }

    private var previewNote: String? {
        if engine.running == .demo { return "Lock your phone or look at CarPlay to see the real card. Stop the demo from Home." }
        return carPlay ? "CarPlay size is approximate; it varies by car." : nil
    }

    // MARK: Panels

    @ViewBuilder private var presets: some View {
        Section {
            grid {
                actionTile("Make your own", symbol: "plus") { startNaming(.new(thenEdit: true)) }
                actionTile("Surprise me", symbol: "dice") { shuffle(.everything) }
                ForEach(mine) { own in
                    tile(own.name, own.style, kind: "look") { apply(own.style, base: own.name) }
                        .contextMenu {
                            Button("Save current look here", systemImage: "square.and.arrow.down") { update(own) }
                                .disabled(own.style == style.withoutCounter)
                            Button("Rename", systemImage: "pencil") { startNaming(.rename(own)) }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = own }
                        }
                }
                if let unsaved = customStyle.flatMap(CardStyle.load), isCustom(unsaved) {
                    tile("Unsaved look", unsaved, kind: "look") { apply(unsaved, base: customBase) }
                }
            }
        } header: {
            Text("My looks")
        } footer: {
            Text("Make your own saves the look you have now under a name; touch and hold it to rename, update or delete it. "
                 + "Surprise me picks a random look that's still easy to read, and the dice at the top shuffle just the colours, font or layout.")
        }
        Section("Presets") {
            grid {
                ForEach(CardPreset.all) { preset in
                    tile(preset.name, preset.style, kind: "preset") { apply(preset.style, base: preset.name) }
                }
            }
        }
    }

    @ViewBuilder private var layout: some View {
        Section {
            grid {
                ForEach(CardStyle.Layout.allCases, id: \.self) { layout in
                    tile(layout.name, styled(layout), kind: "layout", miniature: true) { style.layout = layout }
                }
            }
        } footer: {
            Text("On CarPlay's smaller card, Detailed and Karaoke show the current line first and drop the others when there isn't room.")
        }
        Section {
            Picker("Alignment", selection: $style.alignment) {
                ForEach(CardStyle.Alignment.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Picker("Spacing", selection: $style.spacing) {
                ForEach(CardStyle.Spacing.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        }
        if style.layout != .minimal {
            Section("Show") {
                if style.layout == .detailed || style.layout == .karaoke { Toggle("Song info", isOn: $style.showSongInfo) }
                if style.layout == .detailed { Toggle("Next line", isOn: $style.showNext) }
                Toggle("Progress bar", isOn: $style.showProgress)
                if style.layout == .detailed || style.layout == .karaoke {
                    slider("Other lines", value: $style.dim, in: 0.1...1, step: 0.05,
                           label: "\(style.dim.formatted(.percent.precision(.fractionLength(0)))) bright")
                }
            }
        }
        Section { resetButton("Reset layout", [.layout, .show]) }
    }

    @ViewBuilder private var text: some View {
        Section {
            NavigationLink { FontList(style: $style) } label: {
                LabeledContent("Font") {
                    Text(style.typeface.name).font(style.typeface.font(size: 17, weight: style.weight))
                }
            }
            let weights = style.typeface.weights
            if weights.count == 1 {
                LabeledContent("Weight", value: "\(weights[0].name) only")
            } else {
                // The font's own weights only: asking for one it lacks would draw the nearest anyway.
                Picker("Weight", selection: Binding(get: { style.typeface.nearest(style.weight) }, set: { style.weight = $0 })) {
                    ForEach(weights, id: \.self) { Text($0.name).tag($0) }
                }
            }
            slider(style.layout == .big ? "Largest size" : "Size", value: $style.size, in: 0.3...2.5, step: 0.1,
                   label: style.size.formatted(.percent.precision(.fractionLength(0))))
            slider("Letter spacing", value: $style.tracking, in: -1...8, step: 0.5, label: style.tracking.formatted(.number.precision(.fractionLength(1))))
            slider("Line spacing", value: $style.lineSpacing, in: 0...12, step: 1, label: style.lineSpacing.formatted(.number.precision(.fractionLength(0))))
            Toggle("All caps", isOn: $style.uppercase)
            Toggle("Text shadow", isOn: $style.shadow)
        } footer: {
            if style.layout == .big { Text("Big fits each line as large as it can, up to this size.") }
        }
        Section { resetButton("Reset text", [.text, .font]) }
    }

    @ViewBuilder private var colours: some View {
        Section("Background") {
            Picker("Background", selection: $style.backdrop) {
                ForEach(CardStyle.Backdrop.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch style.backdrop {
            case .color:
                ColorPicker("Colour", selection: color(\.background), supportsOpacity: false)
            case .gradient:
                ColorPicker("Start colour", selection: color(\.background), supportsOpacity: false)
                ColorPicker("End colour", selection: color(\.background2), supportsOpacity: false)
            case .albumArt:
                slider("Darken art", value: $style.artDarkness, in: 0...0.8, step: 0.05,
                       label: style.artDarkness.formatted(.percent.precision(.fractionLength(0))))
            }
        }
        Section("Text") {
            Toggle("Automatic colour", isOn: $style.autoText)
            if !style.autoText { ColorPicker("Text colour", selection: color(\.text), supportsOpacity: false) }
            textContrast
        }
        Section {
            ColorPicker("Accent", selection: color(\.accent), supportsOpacity: false)
            if style.backdrop != .albumArt { accentContrast }
        } header: {
            Text("Accent")
        } footer: {
            Text("Colours the progress bar and the Dynamic Island's ring.")
        }
        Section { resetButton("Reset colours", [.colours]) }
    }

    /// Whether the text reads at a glance: WCAG's 4.5:1 for text, said next to the colour it's about.
    @ViewBuilder private var textContrast: some View {
        if style.backdrop == .albumArt {
            Text(style.autoText
                 ? "Text turns white or near-black to suit each song's art, with a soft shadow for bright spots."
                 : "Album art changes with every song. If lyrics get hard to read on bright covers, darken the art, turn on Text shadow, or use automatic colour.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            let ratio = style.worstContrast(art: nil)
            let shown = ratio.formatted(.number.precision(.fractionLength(1)))
            if ratio >= 4.5 {
                contrast("\(shown):1 · easy to read", good: true)
            } else if style.autoText {
                contrast("\(shown):1 · no single text colour reads well on all of this background, so the text gets a shadow. "
                         + "A gentler gradient or a darker colour reads better.", good: false)
            } else {
                contrast("\(shown):1 · hard to read at a glance. Aim for 4.5:1 or more.", good: false)
                Button("Use automatic colour") { style.autoText = true }
            }
        }
    }

    /// The accent's bars need 3:1 to stand out.
    @ViewBuilder private var accentContrast: some View {
        let ratio = style.backgroundSamples(art: nil).map { style.accent.contrast(with: $0) }.min() ?? 21
        let shown = ratio.formatted(.number.precision(.fractionLength(1)))
        if ratio >= 3 {
            contrast("\(shown):1 · stands out", good: true)
        } else {
            contrast("\(shown):1 · hard to see on this background. Pick a lighter or darker accent.", good: false)
        }
    }

    private func contrast(_ text: String, good: Bool) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(good ? .green : .orange)
        }
        .font(.footnote)
    }

    // MARK: Pieces

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16, content: content)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
    }

    /// A card drawn in `look`, with its name; outlined when it's what you have now. `miniature` shrinks the full Lock
    /// Screen card into the tile, so a layout's extra lines show as they really would.
    private func tile(_ name: String, _ look: CardStyle, kind: String, miniature: Bool = false,
                      action: @escaping () -> Void) -> some View {
        let selected = style.withoutCounter == look.withoutCounter
        return Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if miniature {
                        Color.clear
                            .aspectRatio(360 / 150, contentMode: .fit)
                            .overlay(alignment: .topLeading) {
                                GeometryReader { geometry in
                                    LyricsCard(state: .sample(look))
                                        .frame(width: 360, height: 150)
                                        .scaleEffect(geometry.size.width / 360, anchor: .topLeading)
                                }
                            }
                    } else {
                        LyricsCard(state: .sample(look), small: true).frame(height: 78)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1)
                    }
                Text(name).font(.caption.weight(selected ? .semibold : .regular)).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) \(kind)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A dashed tile that does something rather than showing a look.
    private func actionTile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(height: 78)
                    .overlay { Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.tint) }
                Text(title).font(.caption.weight(.semibold))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func styled(_ layout: CardStyle.Layout) -> CardStyle {
        var copy = style
        copy.layout = layout
        return copy
    }

    /// Puts parts of the style back to their defaults; greyed out when they already are.
    private func resetButton(_ title: String, _ parts: [CardStyle.Part]) -> some View {
        Button(title) { for part in parts { style.reset(part) } }
            .disabled(parts.allSatisfy { style.isDefault($0) })
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(label).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func color(_ path: WritableKeyPath<CardStyle, RGB>) -> Binding<Color> {
        Binding(get: { style[keyPath: path].color }, set: { style[keyPath: path] = RGB($0.resolve(in: environment)) })
    }

    // MARK: Saving

    /// Applies a whole look. An unsaved custom look is kept first, and the update counter stays as it was.
    private func apply(_ look: CardStyle, base: String) {
        keepPrevious()
        var look = look
        look.showCounter = style.showCounter
        style = look
        presetBase = base
    }

    private func shuffle(_ what: CardStyle.Shuffle) {
        keepPrevious()
        var rng = SystemRandomNumberGenerator()
        style = style.shuffled(what, using: &rng)
        if what == .everything { presetBase = "" }
    }

    private func keepPrevious() {
        remember(style)
        previous.append(style)
        if previous.count > 30 { previous.removeFirst() }
    }

    /// Keeps a style that matches no look as the unsaved look, with the look it came from.
    private func remember(_ style: CardStyle) {
        guard isCustom(style) else { return }
        customStyle = try? JSONEncoder().encode(style)
        customBase = presetBase
    }

    // MARK: Your own looks

    private func startNaming(_ kind: Naming) {
        if case .rename(let own) = kind { name = own.name } else { name = UserPreset.unique("My look", among: takenNames) }
        naming = kind
    }

    private var takenNames: [String] { CardPreset.all.map(\.name) + mine.map(\.name) + ["Unsaved look"] }

    private func commitName(_ kind: Naming) {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        var looks = mine
        switch kind {
        case .new(let thenEdit):
            let unique = UserPreset.unique(typed, among: takenNames)
            looks.append(UserPreset(name: unique, style: style))
            presetBase = unique
            if thenEdit { panel = .layout }
        case .rename(let own):
            guard typed != own.name, let index = looks.firstIndex(where: { $0.id == own.id }) else { return }
            looks[index].name = UserPreset.unique(typed, among: takenNames)
            if presetBase == own.name { presetBase = looks[index].name }
            if customBase == own.name { customBase = looks[index].name }
        }
        userPresets = UserPreset.encode(looks)
    }

    /// Saves the current look over one of yours.
    private func update(_ own: UserPreset) {
        userPresets = UserPreset.encode(mine.map { $0.id == own.id ? UserPreset(id: own.id, name: own.name, style: style) : $0 })
        presetBase = own.name
    }

    private func delete(_ own: UserPreset) {
        userPresets = UserPreset.encode(mine.filter { $0.id != own.id })
        if presetBase == own.name { presetBase = "" }
    }

    private func save() {
        guard style != CardStyle.saved else { return }
        CardStyle.saved = style
        remember(style)
        engine.refreshCard()
    }
}

/// Every built-in font, by kind, each name drawn in its own face, under a preview of the card.
struct FontList: View {
    @Binding var style: CardStyle

    var body: some View {
        List {
            ForEach(CardStyle.Typeface.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(CardStyle.Typeface.allCases.filter { $0.category == category }, id: \.self) { face in
                        Button { style.typeface = face } label: {
                            HStack {
                                Text(face.name).font(face.font(size: 19, weight: style.weight))
                                Spacer()
                                if style.typeface == face { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(style.typeface == face ? .isSelected : [])
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            LyricsCard(state: .sample(style))
                .frame(height: 120)
                .clipShape(.rect(cornerRadius: 18))
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension CardPreset {
    /// The preset `style` is, ignoring the update counter (a testing switch, not part of a look).
    static func matching(_ style: CardStyle) -> CardPreset? { all.first { $0.style == style.withoutCounter } }

    static func named(_ name: String) -> CardPreset? { all.first { $0.name == name } }

    /// "Sunset", "Night drive" (one of yours), "Sunset · edited" or "Unsaved look". `base` is the look last applied in
    /// Appearance, which wins when a preset and one of yours look the same.
    static func lookName(_ style: CardStyle, base: String = UserDefaults.standard.string(forKey: "presetBase") ?? "",
                         mine: [UserPreset] = UserPreset.list(UserDefaults.standard.data(forKey: "userPresets"))) -> String {
        let look = style.withoutCounter
        let baseLook = named(base)?.style ?? mine.first { $0.name == base }?.style
        if baseLook == look { return base }
        if let preset = matching(style) { return preset.name }
        if let own = mine.first(where: { $0.style == look }) { return own.name }
        return baseLook == nil ? "Unsaved look" : "\(base) · edited"
    }
}

/// A look saved under its own name from Appearance ("Make your own").
struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Saved JSON, read through CardStyle.load so settings added in later versions don't break saved looks.
    var styleData: Data

    /// The look itself; the update counter is a testing switch, so it isn't part of it.
    var style: CardStyle { CardStyle.load(styleData) ?? CardStyle() }

    init(id: UUID = UUID(), name: String, style: CardStyle) {
        self.id = id
        self.name = name
        styleData = (try? JSONEncoder().encode(style.withoutCounter)) ?? Data()
    }

    static func list(_ data: Data?) -> [UserPreset] {
        data.flatMap { try? JSONDecoder().decode([UserPreset].self, from: $0) } ?? []
    }

    static func encode(_ looks: [UserPreset]) -> Data? { try? JSONEncoder().encode(looks) }

    /// `name`, or "name 2", "name 3"… whichever no look is called yet.
    static func unique(_ name: String, among taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !taken.contains($0) }!
    }
}

extension CardStyle {
    var withoutCounter: CardStyle {
        var copy = self
        copy.showCounter = false
        return copy
    }
}

extension LyricsActivityAttributes.ContentState {
    /// A line from the demo song in `style`, for previews.
    static func sample(_ style: CardStyle) -> Self {
        .init(title: DemoSong.title, artist: DemoSong.artist, current: "Windows down and nothing near",
              next: "Just the line and painted shoulder", previous: "Every mile a little closer", lyrics: .synced,
              lineStart: .now.addingTimeInterval(-1.5), lineEnd: .now.addingTimeInterval(2.5), seq: 42, style: style,
              art: Artwork.sample)
    }
}
