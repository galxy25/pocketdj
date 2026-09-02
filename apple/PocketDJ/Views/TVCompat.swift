#if os(tvOS)
import SwiftUI
import UniformTypeIdentifiers

// tvOS compatibility shims. SwiftUI on tvOS lacks a handful of APIs the shared
// iPhone/iPad/Mac code uses (documents, file pickers, date pickers, disclosure
// groups, swipe actions, scroll-background control). Rather than fencing dozens
// of call sites, this file supplies same-named stand-ins that compile to honest
// no-ops (or minimal focus-friendly equivalents) ONLY on tvOS. Nothing here is
// compiled on iOS/macOS/visionOS, so no existing behavior changes.

// MARK: - FileDocument (documents + exporters are unavailable on tvOS)

/// Stand-in for `SwiftUI.FileDocumentReadConfiguration`.
struct FileDocumentReadConfiguration {
    let contentType: UTType
    let file: FileWrapper
}

/// Stand-in for `SwiftUI.FileDocumentWriteConfiguration`.
struct FileDocumentWriteConfiguration {
    let contentType: UTType
    let existingFile: FileWrapper?
}

/// Minimal stand-in for `SwiftUI.FileDocument` so the app's shared document wrapper
/// types (EditsFile, CSVFile, …) compile unchanged. The exporter/importer modifiers
/// below are no-ops, so these are never actually read or written on tvOS.
protocol FileDocument {
    typealias ReadConfiguration = FileDocumentReadConfiguration
    typealias WriteConfiguration = FileDocumentWriteConfiguration
    static var readableContentTypes: [UTType] { get }
    init(configuration: ReadConfiguration) throws
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
}

extension View {
    /// No-op `fileExporter` (no document picker on tvOS).
    func fileExporter<D: FileDocument>(isPresented: Binding<Bool>, document: D?,
                                       contentType: UTType, defaultFilename: String? = nil,
                                       onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        self
    }

    /// No-op single-selection `fileImporter`.
    func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                      onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        self
    }

    /// No-op multi-selection-capable `fileImporter`.
    func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                      allowsMultipleSelection: Bool,
                      onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        self
    }
}

// MARK: - Swipe actions / scroll background (unavailable on tvOS)

/// Stand-in for `TapGesture`-era modifiers missing from tvOS SwiftUI.
extension View {
    /// No-op: rows expose their actions through context menus on tvOS.
    func swipeActions<T: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true,
                               @ViewBuilder content: () -> T) -> some View {
        self
    }

    /// No-op: tvOS lists keep their standard background.
    func scrollContentBackground(_ visibility: Visibility) -> some View {
        self
    }

    /// No-op: tvOS has no navigation-bar title-display modes.
    func navigationBarTitleDisplayMode(_ mode: TitleDisplayModeShim) -> some View { self }
}

// MARK: - DatePicker (unavailable on tvOS) — read-only date label

/// Stand-in for `SwiftUI.DatePickerComponents`.
struct DatePickerComponents: OptionSet {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let date = DatePickerComponents(rawValue: 1)
    static let hourAndMinute = DatePickerComponents(rawValue: 2)
}

/// Stand-in for `SwiftUI.DatePicker`: renders the chosen value as a plain label.
/// tvOS surfaces that need date entry aren't part of the TV feature set; this keeps
/// shared Settings/filter code compiling without a platform fence at each use.
struct DatePicker: View {
    private let title: String
    @Binding private var selection: Date
    private let components: DatePickerComponents

    init(_ title: String, selection: Binding<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.title = title
        self._selection = selection
        self.components = displayedComponents
    }

    init(_ title: String, selection: Binding<Date>, in range: PartialRangeThrough<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
    }

    init(_ title: String, selection: Binding<Date>, in range: PartialRangeFrom<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
    }

    init(_ title: String, selection: Binding<Date>, in range: ClosedRange<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
    }

    var body: some View {
        HStack {
            if !title.isEmpty { Text(title) }
            Spacer()
            Text(formatted).foregroundStyle(.secondary)
        }
    }

    private var formatted: String {
        if components == [.hourAndMinute] {
            return selection.formatted(date: .omitted, time: .shortened)
        }
        if components == [.date] {
            return selection.formatted(date: .abbreviated, time: .omitted)
        }
        return selection.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Accepts the `.compact` / `.wheel` style tokens so `.datePickerStyle(...)` call
/// sites compile against the stand-in picker; purely inert.
enum DatePickerStyleShim { case automatic, compact, wheel, graphical }
extension View {
    func datePickerStyle(_ style: DatePickerStyleShim) -> some View { self }
}

// MARK: - DisclosureGroup (unavailable on tvOS) — button-toggled section

/// Stand-in for `SwiftUI.DisclosureGroup`: a focusable button that toggles the
/// content's visibility, honoring an external `isExpanded` binding when given.
struct DisclosureGroup<Label: View, Content: View>: View {
    private let external: Binding<Bool>?
    @State private var internalExpanded = false
    private let label: Label
    private let content: () -> Content

    init(isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder label: () -> Label) {
        self.external = isExpanded
        self.content = content
        self.label = label()
    }

    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.external = nil
        self.content = content
        self.label = label()
    }

    private var isExpanded: Bool { external?.wrappedValue ?? internalExpanded }

    var body: some View {
        Group {
            Button {
                if let external { external.wrappedValue.toggle() } else { internalExpanded.toggle() }
            } label: {
                HStack {
                    label
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded { content() }
        }
    }
}

extension DisclosureGroup where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, label: { Text(title) })
    }

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(isExpanded: isExpanded, content: content, label: { Text(title) })
    }
}

// MARK: - Keyboard shortcuts / focus / rows (unavailable on tvOS)

/// Stand-in for `SwiftUI.KeyboardShortcut` (also unavailable on tvOS): carries the
/// two semantic tokens the app uses.
struct KeyboardShortcutShim {
    static let cancelAction = KeyboardShortcutShim()
    static let defaultAction = KeyboardShortcutShim()
}

extension View {
    /// No-op: no hardware-keyboard shortcut surface on tvOS.
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        self
    }

    /// No-op semantic-shortcut variant (`.cancelAction` / `.defaultAction`).
    func keyboardShortcut(_ shortcut: KeyboardShortcutShim) -> some View { self }

    /// No-op: search focus is driven by the focus engine on tvOS.
    func searchFocused(_ binding: FocusState<Bool>.Binding) -> some View { self }

    /// No-op: tvOS lists manage their own separators.
    func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        self
    }

    /// No-op: drag-and-drop payloads have no drop targets on tvOS.
    func draggable<T: Transferable>(_ payload: T) -> some View { self }

    /// No-op drag-with-preview variant.
    func draggable<T: Transferable, P: View>(_ payload: T,
                                             @ViewBuilder preview: () -> P) -> some View { self }

    /// No-op drop target (no drag-and-drop on tvOS).
    func dropDestination<T: Transferable>(for payloadType: T.Type,
                                          action: @escaping ([T], CGPoint) -> Bool,
                                          isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        self
    }

    /// No-op popover (the `(isPresented:arrowEdge:)` shape the app uses): the
    /// long-press chip popovers are a touch affordance, not part of the TV set.
    func popover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge,
                                @ViewBuilder content: () -> Content) -> some View {
        self
    }
}

/// Accepts the `NavigationBarItem.TitleDisplayMode` tokens; inert on tvOS.
enum TitleDisplayModeShim { case automatic, inline, large }

/// Accepts `.roundedBorder` so shared TextFields compile; inert (tvOS draws its own
/// field chrome). Deliberately has NO `.plain`/`.automatic` cases — those resolve to
/// the real tvOS `TextFieldStyle` members without ambiguity.
enum RoundedBorderTextFieldStyleShim { case roundedBorder }
extension View {
    func textFieldStyle(_ style: RoundedBorderTextFieldStyleShim) -> some View { self }
}

/// Accepts `.button` for `.toggleStyle(...)`; renders as the default tvOS toggle.
/// No `.switch`/`.automatic` cases — those resolve to the real members.
enum ButtonToggleStyleShim { case button }
extension View {
    func toggleStyle(_ style: ButtonToggleStyleShim) -> some View { self }
}

// MARK: - DragGesture (unavailable on tvOS) — inert gesture

/// Stand-in for `SwiftUI.DragGesture`: conforms to `Gesture` (so `some Gesture`
/// builders compile) but is built on a long-press that never completes — drag
/// handlers simply never fire on tvOS.
struct DragGesture: Gesture {
    struct Value: Equatable {
        var time: Date = Date()
        var location: CGPoint = .zero
        var startLocation: CGPoint = .zero
        var translation: CGSize = .zero
        var velocity: CGSize = .zero
        var predictedEndLocation: CGPoint = .zero
        var predictedEndTranslation: CGSize = .zero
    }

    init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {}

    var body: some Gesture<Value> {
        LongPressGesture(minimumDuration: 86_400 * 365).map { _ in Value() }
    }
}

/// Stand-in for `SwiftUI.SpatialTapGesture` (tap-with-location is a touch/pointer
/// affordance): never fires on tvOS.
struct SpatialTapGesture: Gesture {
    struct Value: Equatable {
        var location: CGPoint = .zero
    }

    init(count: Int = 1, coordinateSpace: CoordinateSpace = .local) {}

    var body: some Gesture<Value> {
        LongPressGesture(minimumDuration: 86_400 * 365).map { _ in Value() }
    }
}

// MARK: - ShareLink (unavailable on tvOS) — renders nothing

/// Stand-in for `SwiftUI.ShareLink`: sharing has no share sheet on tvOS, so the
/// link simply doesn't render (menus lose their Share row on TV only).
struct ShareLink<Label: View>: View {
    init<Item>(item: Item, subject: Text? = nil, message: Text? = nil,
               @ViewBuilder label: () -> Label) {}
    var body: some View { EmptyView() }
}

extension ShareLink where Label == SwiftUI.Label<Text, Image> {
    init<Item>(item: Item, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) {
            SwiftUI.Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Stepper (unavailable on tvOS) — focusable −/＋ buttons

/// Stand-in for `SwiftUI.Stepper`: the label plus two focusable −/＋ buttons.
struct Stepper<Label: View, V: Strideable>: View {
    @Binding private var value: V
    private let bounds: ClosedRange<V>
    private let step: V.Stride
    private let label: Label

    init(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
         @ViewBuilder label: () -> Label) {
        self._value = value
        self.bounds = bounds
        self.step = step
        self.label = label()
    }

    var body: some View {
        HStack {
            label
            Spacer()
            Button("−") { bump(-1) }.buttonStyle(.bordered)
            Button("＋") { bump(1) }.buttonStyle(.bordered)
        }
    }

    private func bump(_ direction: Int) {
        let next = value.advanced(by: direction > 0 ? step : .zero - step)
        value = min(max(next, bounds.lowerBound), bounds.upperBound)
    }
}

extension Stepper where Label == Text {
    init(_ title: String, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1) {
        self.init(value: value, in: bounds, step: step) { Text(title) }
    }
}

// MARK: - Slider (unavailable on tvOS) — read-only level bar

/// Stand-in for `SwiftUI.Slider`: renders the value as a progress bar. Continuous
/// scrubbing/level input isn't a TV affordance; surfaces that need adjustment on TV
/// get dedicated focus-friendly controls instead.
struct Slider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    @Binding private var value: V
    private let bounds: ClosedRange<V>

    init(value: Binding<V>, in bounds: ClosedRange<V> = 0...1,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.bounds = bounds
    }

    init(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: value, in: bounds, onEditingChanged: onEditingChanged)
    }

    var body: some View {
        ProgressView(value: fraction)
    }

    private var fraction: Double {
        let span = Double(bounds.upperBound - bounds.lowerBound)
        guard span > 0 else { return 0 }
        let f = (Double(value) - Double(bounds.lowerBound)) / span
        return min(max(f, 0), 1)
    }
}

// MARK: - Text selection / pasteboard (unavailable on tvOS)

/// Accepts `.enabled`/`.disabled` for `.textSelection(...)`; inert on tvOS.
enum TextSelectionShim { case enabled, disabled }
extension View {
    func textSelection(_ selectability: TextSelectionShim) -> some View { self }
}

/// Stand-in for `UIKit.UIPasteboard` (no system pasteboard on tvOS): an in-process
/// scratch board, so Copy buttons compile and are harmless no-ops across app runs.
final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String?
    var items: [[String: Any]] = []
    func data(forPasteboardType type: String) -> Data? {
        items.first?[type] as? Data
    }
    func contains(pasteboardTypes types: [String]) -> Bool {
        items.contains { row in types.contains { row[$0] != nil } }
    }
}

// MARK: - App Intents

/// Stand-in for `AppIntents.IndexedEntity` (Spotlight indexing; no Spotlight on tvOS).
protocol IndexedEntity {}
#endif
