import SwiftUI

/// The reader's chip look, shared by the voice · speed chip, the sleep chip
/// and the one chip above the bar: outlined paper (surface with a border)
/// that turns surface2 while pressed, a capsule below accessibility sizes
/// and a rounded rectangle that wraps to two lines at them. `isOn` (an
/// armed timer) is accentStrong on accentSoft, laid over the same ground so
/// a press still deepens it. The visible chip is about 34pt; the hit area
/// is the full 44, and only the visible shape moves on a press.
///
/// The label always keeps its type size: a chip that can't fit says less
/// (a short form), never in smaller type.
struct ReaderChipStyle: ViewModifier {

    var isOn = false
    /// The label's colour at rest when not on.
    var tint: Color = Theme.text

    /// The visible chip never outgrows the skip targets, so Play stays the
    /// bar's largest control at every text size.
    static let maxHeight: CGFloat = PlayerBarLayout.skipTargetRange.upperBound
    static let pressedScale: CGFloat = 0.97

    /// The ground under the chip: surface at rest, surface2 while pressed.
    static func ground(isPressed: Bool) -> Color {
        isPressed ? Theme.surface2 : Theme.surface
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readerChipIsPressed) private var isPressed
    @ScaledMetric(relativeTo: .footnote) private var scaledHeight: CGFloat = 34

    private var height: CGFloat { min(scaledHeight, Self.maxHeight) }

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            chip(content, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous),
                 isAccessibilitySize: true)
        } else {
            chip(content, in: Capsule(), isAccessibilitySize: false)
        }
    }

    private func chip<S: InsettableShape>(_ content: Content, in shape: S,
                                          isAccessibilitySize: Bool) -> some View {
        content
            .font(Theme.font(.subhead))
            .lineLimit(isAccessibilitySize ? 2 : 1)
            .foregroundStyle(isOn ? Theme.accentStrong : tint)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, isAccessibilitySize ? Theme.Space.xxs : .zero)
            .frame(minWidth: height, minHeight: height)
            .background {
                ZStack {
                    shape.fill(Self.ground(isPressed: isPressed))
                    if isOn { shape.fill(Theme.accentSoft) }
                }
            }
            .overlay(shape.strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            // The shape settles under the finger; Reduce Motion keeps the
            // colour change alone.
            .scaleEffect(isPressed && !reduceMotion ? Self.pressedScale : 1)
            .animation(.easeOut(duration: Theme.Motion.press), value: isPressed)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A chip button: the chip look, pressed like a control (surface2 and a
/// slight settle) rather than the system's opacity dim.
struct ReaderChipButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .readerChip(isOn: isOn, tint: tint)
            .environment(\.readerChipIsPressed, configuration.isPressed)
    }
}

/// Hands a press to a label that draws its own chip face (`readerChip`), as
/// a Menu's label does: where the system styles the menu's button, the chip
/// presses like the others; where it doesn't, the chip still looks the same.
struct ReaderChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.readerChipIsPressed, configuration.isPressed)
    }
}

/// A transport glyph (back and forward 15): textMuted at rest, so Play
/// stays the heaviest mark in the bar; Theme.text and a slight settle while
/// pressed (the colour alone under Reduce Motion).
struct ReaderGlyphButtonStyle: ButtonStyle {
    static let pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        ReaderGlyphFace(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct ReaderGlyphFace<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(isPressed ? Theme.text : Theme.textMuted)
            .scaleEffect(isPressed && !reduceMotion ? ReaderGlyphButtonStyle.pressedScale : 1)
            .animation(.easeOut(duration: Theme.Motion.press), value: isPressed)
    }
}

/// The widest chip in the bar with its full label, so the bar can tell
/// whether a tighter gap beside Play would let the chips keep their words.
struct ReaderChipFullWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReaderChipIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The chip's button is held down.
    var readerChipIsPressed: Bool {
        get { self[ReaderChipIsPressedKey.self] }
        set { self[ReaderChipIsPressedKey.self] = newValue }
    }
}

extension View {
    /// The reader's chip look; `isOn` marks an armed state.
    func readerChip(isOn: Bool = false, tint: Color = Theme.text) -> some View {
        modifier(ReaderChipStyle(isOn: isOn, tint: tint))
    }

    /// Reports the chip's width with its `full` label, which it may not be
    /// showing, through `ReaderChipFullWidth`. An invisible copy, out of
    /// layout, hit testing and the accessibility tree.
    func readerChipFullWidth<Full: View>(isOn: Bool = false, @ViewBuilder _ full: () -> Full) -> some View {
        background(alignment: .leading) {
            full()
                .readerChip(isOn: isOn)
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ReaderChipFullWidth.self, value: proxy.size.width)
                })
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
