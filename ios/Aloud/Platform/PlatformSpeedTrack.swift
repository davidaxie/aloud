import SwiftUI
#if os(iOS)
import UIKit
#endif

// The speed track's input (R3-09): its drag and its accessibility element,
// which each platform takes its own way. The look (`WarmTrack`) and the
// rules (`SpeedTrack`, `SpeedScale`) are shared; `ListeningSpeedControls`
// hands them here as one `SpeedTrackInput`.
//
// The iPhone's track sits in a sheet, and at the accessibility sizes in a
// scroll view, whose pans must keep every vertical drag that starts on it.
// SwiftUI's DragGesture, alongside them or not, held those drags (the sheet
// stayed put and the voices never scrolled), and the stock slider kept only
// as an accessibilityRepresentation is never laid out, so UI automation
// found no thumb positions to drag between. So the iPhone's half is UIKit:
// a pan that declines any drag that isn't sideways, and a real UISlider that
// draws nothing as the element. The Mac's pointer has no sheet to give way
// to and scrolls with the wheel: a click sets the speed there, as its stock
// slider did, and the representation is the element.

/// What the speed control hands the platform: the speed, what assistive
/// tech hears, and what a drag or an adjustment does.
struct SpeedTrackInput {
    /// The speed now, on `range`.
    let rate: Double
    let range: ClosedRange<Double>
    /// The element's label and identifier.
    let label: String
    let identifier: String
    /// What assistive tech hears for a speed.
    let spokenValue: (Double) -> String
    /// A drag that is the track's moved: where it started and where it is
    /// now, along a track `width` wide.
    let onDrag: (_ startX: CGFloat, _ x: CGFloat, _ width: CGFloat) -> Void
    /// That drag lifted, or the system cancelled it.
    let onRelease: () -> Void
    /// One adjustable step up (true) or down: the speed it lands on.
    let onStep: (_ increment: Bool) -> Double
    /// An assistive write of a raw speed, where the element takes one (the
    /// Mac's).
    let onSet: (Double) -> Void
}

extension View {
    /// The speed track's drag and accessibility element, the platform's
    /// way, over a view that draws the track and fills its touch row.
    func speedTrackInput(_ input: SpeedTrackInput) -> some View {
        modifier(PlatformSpeedTrackInput(input: input))
    }
}

#if os(iOS)
/// The iPhone's half: `SpeedTrackSurface` over the drawn track takes its
/// touches and is its accessibility element.
struct PlatformSpeedTrackInput: ViewModifier {
    let input: SpeedTrackInput

    func body(content: Content) -> some View {
        content.overlay { SpeedTrackSurface(input: input) }
    }
}

/// A clear UIKit view the size of the track's touch row. Its pan begins only
/// on a drag more sideways than down (`SpeedTrack.beginsSideways`), and the
/// scroll view's and the sheet's pans wait on that choice, so a vertical
/// drag from the row is theirs from its first point and a sideways one is
/// the track's alone. Its `SpeedTrackSlider` is the element.
struct SpeedTrackSurface: UIViewRepresentable {
    let input: SpeedTrackInput

    func makeCoordinator() -> Coordinator { Coordinator(input: input) }

    func makeUIView(context: Context) -> SpeedTrackSurfaceView {
        let surface = SpeedTrackSurfaceView()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        surface.addGestureRecognizer(pan)
        let coordinator = context.coordinator
        surface.slider.onStep = { [weak coordinator] increment in coordinator?.input.onStep(increment) }
        Self.show(input, on: surface.slider)
        return surface
    }

    func updateUIView(_ surface: SpeedTrackSurfaceView, context: Context) {
        context.coordinator.input = input
        Self.show(input, on: surface.slider)
    }

    /// The element reads the speed now, under the control's label and
    /// identifier.
    static func show(_ input: SpeedTrackInput, on slider: SpeedTrackSlider) {
        slider.minimumValue = Float(input.range.lowerBound)
        slider.maximumValue = Float(input.range.upperBound)
        slider.spokenValue = input.spokenValue
        slider.rate = input.rate
        slider.accessibilityLabel = input.label
        slider.accessibilityIdentifier = input.identifier
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var input: SpeedTrackInput
        /// Where the drag in progress touched down; nil with none.
        private var startX: CGFloat?

        init(input: SpeedTrackInput) {
            self.input = input
        }

        @objc func pan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let x = pan.location(in: view).x
            switch pan.state {
            case .began:
                // The touch-down point, so a drag that began on the thumb
                // carries it from where the finger first met it.
                let start = x - pan.translation(in: view).x
                startX = start
                input.onDrag(start, x, view.bounds.width)
            case .changed:
                guard let startX else { return }
                input.onDrag(startX, x, view.bounds.width)
            case .ended, .cancelled, .failed:
                guard startX != nil else { return }
                startX = nil
                input.onRelease()
            default:
                break
            }
        }

        /// Only a drag more sideways than down is the track's. Its travel
        /// when the pan would begin, or its velocity if it has none yet.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            var travel = pan.translation(in: pan.view)
            if travel == .zero { travel = pan.velocity(in: pan.view) }
            return SpeedTrack.beginsSideways(CGSize(width: travel.x, height: travel.y))
        }

        /// The pans of the views around the track (the scroll view's, the
        /// sheet's) wait for this one to decline before they begin, so the
        /// two never race for a drag that starts on the row.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard other is UIPanGestureRecognizer, let mine = recognizer.view, let theirs = other.view,
                  theirs !== mine else { return false }
            return mine.isDescendant(of: theirs)
        }
    }
}

/// Holds the element across the whole touch row. The row's touches land
/// here, on the pan: the slider takes none.
final class SpeedTrackSurfaceView: UIView {
    let slider = SpeedTrackSlider()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        slider.frame = bounds
        slider.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        slider.isUserInteractionEnabled = false
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// A UISlider that draws nothing (the warm track under it is the drawing):
/// VoiceOver's adjustable slider with the speed as its value and the
/// scale's 0.05 step, and its thumb where `WarmTrack` draws the thumb, so
/// the positions UI automation drags between are the track's own.
final class SpeedTrackSlider: UISlider {
    /// The speed shown, unrounded by Float.
    var rate: Double = 1 {
        didSet { value = Float(rate) }
    }
    var spokenValue: (Double) -> String = { _ in "" }
    /// An adjustable step: the speed it lands on.
    var onStep: ((Bool) -> Double?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let none = UIImage()
        setThumbImage(none, for: .normal)
        setMinimumTrackImage(none, for: .normal)
        setMaximumTrackImage(none, for: .normal)
        minimumTrackTintColor = .clear
        maximumTrackTintColor = .clear
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The warm track's resting line: the row's whole width, centred.
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.midY - ScrubThumb.trackHeight / 2,
               width: bounds.width, height: ScrubThumb.trackHeight)
    }

    /// The warm track's 12pt thumb at `value`, centred on the fill's end and
    /// kept inside the track (`WarmTrack.thumbCentre`).
    override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
        let span = maximumValue - minimumValue
        let fraction = span > 0 ? Double((value - minimumValue) / span) : 0
        let diameter = ScrubThumb.diameter
        let centre = bounds.minX + WarmTrack.thumbCentre(fraction: fraction, width: bounds.width)
        return CGRect(x: centre - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
    }

    /// Adjustable, and never dimmed for taking no touches of its own (the
    /// surface's pan takes them), whatever the slider's own traits say.
    override var accessibilityTraits: UIAccessibilityTraits {
        get { super.accessibilityTraits.union(.adjustable).subtracting(.notEnabled) }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityValue: String? {
        get { spokenValue(rate) }
        set {}
    }

    override func accessibilityIncrement() { step(up: true) }

    override func accessibilityDecrement() { step(up: false) }

    /// The value moves with the step at once, so VoiceOver reads the speed
    /// it landed on, not the one before.
    private func step(up: Bool) {
        guard let landed = onStep?(up) else { return }
        rate = landed
    }
}
#elseif os(macOS)
/// The Mac's half: a press is the track's from its first frame, so a click
/// sets the speed under the pointer and a drag carries on from it, as the
/// stock macOS slider and MacScrub's click do. To assistive tech it is the
/// stock slider.
struct PlatformSpeedTrackInput: ViewModifier {
    let input: SpeedTrackInput

    /// A press in progress. Gesture state, so a system cancel clears it as
    /// a release does, and either way the release is reported.
    @GestureState private var isPressed = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .updating($isPressed) { value, pressed, _ in
                    pressed = true
                    input.onDrag(value.startLocation.x, value.location.x, width)
                })
            .onChange(of: isPressed) { wasPressed, pressed in
                if wasPressed, !pressed { input.onRelease() }
            }
            // A slider to assistive tech (the scrub's pattern): this swaps
            // the accessibility alone; the press stays on the track.
            .accessibilityRepresentation {
                Slider(value: Binding(get: { input.rate }, set: { input.onSet($0) }), in: input.range)
                    // The whole touch row, so the element's frame is the
                    // one the press uses.
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                    .accessibilityLabel(input.label)
                    .accessibilityValue(input.spokenValue(input.rate))
                    .accessibilityAdjustableAction { direction in
                        _ = input.onStep(direction == .increment)
                    }
                    .accessibilityIdentifier(input.identifier)
            }
    }
}
#endif
