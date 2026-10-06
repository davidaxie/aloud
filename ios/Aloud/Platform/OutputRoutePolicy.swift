import Foundation

/// One audio output device as the headphones rule sees it: CoreAudio's
/// device ID, how it is attached, and (for the built-in output) whether the
/// jack or the speakers are playing.
struct OutputDevice: Equatable, Sendable {

    /// `kAudioDevicePropertyTransportType`, reduced to what the rule and
    /// its logs need.
    enum Transport: Equatable, Sendable {
        case builtIn, bluetooth, bluetoothLE, usb, airPlay, hdmi, displayPort, aggregate, virtual, unknown

        init(code: UInt32) {
            switch code {
            case fourCharCode("bltn"): self = .builtIn
            case fourCharCode("blue"): self = .bluetooth
            case fourCharCode("blea"): self = .bluetoothLE
            case fourCharCode("usb "): self = .usb
            case fourCharCode("airp"): self = .airPlay
            case fourCharCode("hdmi"): self = .hdmi
            case fourCharCode("dprt"): self = .displayPort
            case fourCharCode("grup"): self = .aggregate
            case fourCharCode("virt"): self = .virtual
            default: self = .unknown
            }
        }
    }

    /// `kAudioDevicePropertyDataSource` on the built-in output.
    enum DataSource: Equatable, Sendable {
        case headphones, speakers, other(UInt32)

        init(code: UInt32) {
            switch code {
            case fourCharCode("hdpn"): self = .headphones
            case fourCharCode("ispk"): self = .speakers
            default: self = .other(code)
            }
        }
    }

    let id: UInt32
    let transport: Transport
    /// Nil where the device has no data source, or it couldn't be read.
    let dataSource: DataSource?
}

/// What playback does after the output changed under it.
enum RouteDecision: Equatable, Sendable {
    /// Pause with an honest reason: the audio would otherwise move to the
    /// speakers mid-sentence.
    case stop(StopReason)
    /// Rebind and restart on the current device, from the sentence start,
    /// with no notice.
    case follow
    /// Nothing that playback needs to act on.
    case ignore
}

/// What `AudioOutputMonitoring.activate()` throws when a call, or an app
/// that outranks Aloud, holds the audio: playback pauses as interrupted,
/// not failed. Only an iPhone throws it.
struct AudioOutputHeldElsewhere: Error, Equatable {}

/// The headphones rule (M12), pure so both hosts test the same table.
/// Speech never falls through to the speakers: it stops when the device
/// that was playing disappears, or when the built-in output's source moves
/// off the headphone jack. It follows when the listener picks another output
/// while the old one still exists, and through a format change on the same
/// device.
enum OutputRoutePolicy {

    /// - Parameters:
    ///   - previous: the device bound at Play; nil when nothing is bound.
    ///   - current: the system's default output now; nil when there is none.
    ///   - previousStillPresent: whether `previous` is still attached and alive.
    static func decide(previous: OutputDevice?,
                       current: OutputDevice?,
                       previousStillPresent: Bool) -> RouteDecision {
        guard let previous else { return .ignore }
        // AirPods died or a USB DAC was pulled: whatever is left is likely
        // the speakers.
        guard previousStillPresent else { return .stop(.headphonesDisconnected) }
        // The bound device still plays; there is nothing better to move to.
        guard let current else { return .ignore }
        if current.id == previous.id,
           previous.dataSource == .headphones,
           current.dataSource != .headphones {
            // Wired headphones unplugged: the same built-in device, now
            // playing through its speakers.
            return .stop(.headphonesDisconnected)
        }
        // The listener's own switch, a format change, or headphones plugged
        // into the built-in jack.
        return .follow
    }
}

/// CoreAudio's four-character codes ('blue', 'hdpn'), spelled as text so this
/// file needs no CoreAudio import and compiles for the iPhone's tests.
private func fourCharCode(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}
