import SwiftUI

/// The player bar's chip look, shared by the voice · speed chip and the sleep
/// chip: a capsule below accessibility sizes, a rounded rectangle that wraps
/// to two lines at them. `isOn` (an armed timer) is accentStrong on
/// accentSoft. The visible chip is about 34pt; the hit area is the full 44.
struct ReaderChipStyle: ViewModifier {

    var isOn = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 34

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
            .minimumScaleFactor(0.75)
            .foregroundStyle(isOn ? Theme.accentStrong : Theme.text)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, isAccessibilitySize ? Theme.Space.xxs : .zero)
            .frame(minWidth: height, minHeight: height)
            .background(isOn ? Theme.accentSoft : Theme.surface2, in: shape)
            .overlay(shape.strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    /// The player bar's chip look; `isOn` marks an armed state.
    func readerChip(isOn: Bool = false) -> some View {
        modifier(ReaderChipStyle(isOn: isOn))
    }
}
