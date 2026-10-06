#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// The Mac's `AudioOutputMonitoring` (S7, S7b, S8). A Mac has no audio
/// session and nothing takes an app's audio, so `activate`, `deactivate` and
/// `onInterruption` do nothing. What it does instead:
/// - pins the engine's output to the device chosen at Play
///   (`kAudioOutputUnitProperty_CurrentDevice`), so speech never falls
///   through to the speakers when that device vanishes;
/// - listens to the HAL (the default output, the device list, and the bound
///   device's life and data source) and asks `OutputRoutePolicy` what each
///   change means: a stop pauses through `onRouteRequiresPause`, and a
///   device the listener picked is followed;
/// - answers the controller's question after `.AVAudioEngineConfigurationChange`
///   with the same rule.
@MainActor
final class MacAudioOutputMonitor: AudioOutputMonitoring {

    #if DEBUG
    /// The monitor the app built, for the UI-test faults (S8).
    private(set) static weak var current: MacAudioOutputMonitor?
    #endif

    /// Never called: macOS has no audio-session interruptions.
    var onInterruption: ((AudioInterruption) -> Void)?
    var onRouteRequiresPause: (() -> Void)?

    private let hardware: any AudioHardwareReading
    /// The device bound at Play, as the rule last saw it. Nil until the
    /// first bind, and so the rule ignores every change before one.
    private(set) var bound: OutputDevice?
    /// The engine pinned to `bound`.
    private weak var engine: AVAudioEngine?
    /// How long a switch the rule would follow is left to settle before
    /// the rule runs again and follows it.
    private let settleInterval: TimeInterval
    private var followPending = false
    /// The engine stopped itself while the switch settled, so the settled
    /// follow restarts it whatever it plays to now.
    private var engineStoppedWhileSettling = false
    /// The default output a settle confirmed as the listener's switch: a
    /// change onto it is followed at once.
    private var settledDevice: AudioObjectID?

    /// `hardware` nil is the system's HAL; tests inject a fake, and a zero
    /// `settleInterval` to follow at once.
    init(hardware: (any AudioHardwareReading)? = nil, settleInterval: TimeInterval = 0.5) {
        self.hardware = hardware ?? SystemAudioHardware()
        self.settleInterval = settleInterval
        self.hardware.onChange = { [weak self] in self?.hardwareChanged() }
        #if DEBUG
        Self.current = self
        #endif
    }

    /// No session to claim: a Mac app plays to its device without asking.
    func activate() throws {}

    func deactivate() {}

    /// Pins the engine to today's default output: when that device goes
    /// away, the output fails instead of following the system default to
    /// the speakers. Never offline, where there is no device at all.
    func bindOutput(of engine: AVAudioEngine) {
        guard !engine.isInManualRenderingMode else { return }
        guard let id = hardware.defaultOutputDevice else {
            bound = nil
            return
        }
        hardware.bind(engine, to: id)
        self.engine = engine
        bound = device(id)
        settledDevice = nil
        hardware.watch(device: id)
    }

    /// A stop acts at once. A follow onto another device waits for the HAL
    /// to settle, as a listener's does (`hardwareChanged`): departing AirPods
    /// can read as the speakers becoming the default while still listed,
    /// and following then would carry speech to the speakers. Meanwhile
    /// nothing acts (`.ignore`); once settled, the rule runs again and stops,
    /// or posts the change again to be followed. A format change on the
    /// bound device, or a switch already settled, is followed at once.
    func decisionAfterConfigurationChange() -> RouteDecision {
        let decision = currentDecision()
        switch decision {
        case .stop:
            settleAfterStop()
        case .follow where followNeedsToSettle:
            engineStoppedWhileSettling = true
            settleThenFollow()
            return .ignore
        case .follow, .ignore:
            break
        }
        return decision
    }

    /// Whether following now would move the engine onto a device no settle
    /// has confirmed yet.
    private var followNeedsToSettle: Bool {
        guard settleInterval > 0, let current = hardware.defaultOutputDevice else { return false }
        return current != bound?.id && current != settledDevice
    }

    /// One device as the rule sees it: its transport, and the built-in
    /// output's source (jack or speakers).
    func device(_ id: AudioObjectID) -> OutputDevice {
        OutputDevice(id: id,
                     transport: OutputDevice.Transport(code: hardware.transportType(of: id) ?? 0),
                     dataSource: hardware.dataSource(of: id).map(OutputDevice.DataSource.init(code:)))
    }

    // MARK: - Deciding

    /// What the rule says about the output as it is now.
    private func currentDecision() -> RouteDecision {
        OutputRoutePolicy.decide(previous: bound,
                                 current: hardware.defaultOutputDevice.map(device(_:)),
                                 previousStillPresent: bound.map { isPresent($0.id) } ?? false)
    }

    private func isPresent(_ id: AudioObjectID) -> Bool {
        hardware.devices.contains(id) && hardware.isAlive(id)
    }

    /// A HAL listener fired: the default output, the device list, or the
    /// bound device's life or source changed.
    private func hardwareChanged() {
        switch currentDecision() {
        case .stop:
            settleAfterStop()
            onRouteRequiresPause?()
        case .follow:
            // AirPods going away can reach this listener as a new default
            // output before they leave the device list. Following at once
            // would carry speech to the speakers, so the rule runs again
            // once the HAL has settled, and stops then if they are gone.
            settleThenFollow()
        case .ignore:
            return
        }
    }

    /// Runs the rule again once the HAL has settled (at once with no
    /// settle), unless a run is already on its way.
    private func settleThenFollow() {
        guard !followPending else { return }
        guard settleInterval > 0 else { return followIfStillChosen() }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval) { [weak self] in
            MainActor.assumeIsolated { self?.followIfStillChosen() }
        }
    }

    /// The switch, settled: a stop now pauses; a follow still standing
    /// moves the engine. The pinned engine doesn't move to a device the
    /// listener picked, so it gets the change the engine posts for a format
    /// change, and the controller rebinds from the sentence start. The same
    /// device (the jack's source moving to headphones) has nothing to move,
    /// and a stopped engine binds at the next Play, unless it stopped itself
    /// while the switch settled: then the change is posted again, and the
    /// controller restarts it on the output as it is now.
    private func followIfStillChosen() {
        followPending = false
        let engineStopped = engineStoppedWhileSettling
        engineStoppedWhileSettling = false
        switch currentDecision() {
        case .stop:
            settleAfterStop()
            onRouteRequiresPause?()
        case .follow:
            guard let current = hardware.defaultOutputDevice else { return }
            settledDevice = current
            guard let engine,
                  (engine.isRunning && current != bound?.id) || (engineStopped && !engine.isRunning) else { return }
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        case .ignore:
            return
        }
    }

    /// After a stop on a device that is still here (headphones pulled from
    /// the jack), the rule compares against it as it is now, so a Play the
    /// listener chooses on the speakers isn't stopped again. A device that
    /// is gone stays bound: every later change still reads as the stop
    /// until the next Play binds afresh.
    private func settleAfterStop() {
        guard let id = bound?.id, isPresent(id) else { return }
        bound = device(id)
    }

    #if DEBUG
    /// The route changes a UI test injects.
    enum SimulatedChange {
        /// The private device playback was bound to (AirPods) vanished and
        /// the built-in speakers took over.
        case privateToPublic
    }

    /// Runs the rule over `change` and acts on it as on a real one, with no
    /// hardware touched (the `-uitest-fault route` path, S8).
    func simulate(_ change: SimulatedChange) {
        switch change {
        case .privateToPublic:
            let id = bound?.id ?? 0
            let headphones = OutputDevice(id: id, transport: .bluetooth, dataSource: nil)
            let speakers = OutputDevice(id: id &+ 1, transport: .builtIn, dataSource: .speakers)
            let decision = OutputRoutePolicy.decide(previous: headphones, current: speakers,
                                                    previousStillPresent: false)
            if case .stop = decision { onRouteRequiresPause?() }
        }
    }
    #endif
}

// MARK: - The HAL

/// What the monitor reads from CoreAudio, and the listeners it hangs there.
/// The system's HAL in the app; a fake in tests, so classification and the
/// rule run with no hardware.
@MainActor
protocol AudioHardwareReading: AnyObject {
    /// Called on the main thread when the default output or the device list
    /// changes, or the watched device dies or changes its data source.
    var onChange: (@MainActor () -> Void)? { get set }
    /// `kAudioHardwarePropertyDefaultOutputDevice`; nil when there is none.
    var defaultOutputDevice: AudioObjectID? { get }
    /// `kAudioHardwarePropertyDevices`.
    var devices: [AudioObjectID] { get }
    /// `kAudioDevicePropertyDeviceIsAlive`.
    func isAlive(_ device: AudioObjectID) -> Bool
    /// `kAudioDevicePropertyTransportType`; nil when it can't be read.
    func transportType(of device: AudioObjectID) -> UInt32?
    /// `kAudioDevicePropertyDataSource` on the output scope; nil where the
    /// device has none.
    func dataSource(of device: AudioObjectID) -> UInt32?
    /// Starts listening to the system (once) and to `device`, replacing the
    /// device watched before.
    func watch(device: AudioObjectID)
    /// Points `engine`'s output unit at `device`. The engine is stopped.
    func bind(_ engine: AVAudioEngine, to device: AudioObjectID)
}

/// The system's HAL. Nothing listens before the first bind.
@MainActor
final class SystemAudioHardware: AudioHardwareReading {

    var onChange: (@MainActor () -> Void)?

    private var systemListeners: HALListeners?
    private var deviceListeners: HALListeners?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    var defaultOutputDevice: AudioObjectID? {
        Self.readUInt32(kAudioHardwarePropertyDefaultOutputDevice, of: Self.system)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    var devices: [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    func isAlive(_ device: AudioObjectID) -> Bool {
        Self.readUInt32(kAudioDevicePropertyDeviceIsAlive, of: device).map { $0 != 0 } ?? false
    }

    func transportType(of device: AudioObjectID) -> UInt32? {
        Self.readUInt32(kAudioDevicePropertyTransportType, of: device)
    }

    func dataSource(of device: AudioObjectID) -> UInt32? {
        Self.readUInt32(kAudioDevicePropertyDataSource, of: device, scope: kAudioDevicePropertyScopeOutput)
    }

    func watch(device: AudioObjectID) {
        if systemListeners == nil {
            let listeners = HALListeners(block: listenerBlock())
            listeners.add(Self.address(kAudioHardwarePropertyDefaultOutputDevice), on: Self.system)
            listeners.add(Self.address(kAudioHardwarePropertyDevices), on: Self.system)
            systemListeners = listeners
        }
        // Releasing the old set removes its listeners.
        let listeners = HALListeners(block: listenerBlock())
        listeners.add(Self.address(kAudioDevicePropertyDeviceIsAlive), on: device)
        listeners.add(Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
                      on: device)
        deviceListeners = listeners
    }

    func bind(_ engine: AVAudioEngine, to device: AudioObjectID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioObjectID>.size))
    }

    /// Delivered on the main queue, so the monitor decides on the main actor.
    private func listenerBlock() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readUInt32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Listeners added with one block, removed with that same block (CoreAudio
/// matches removals by block identity) when the set is released.
private final class HALListeners {

    private let block: AudioObjectPropertyListenerBlock
    private var added: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []

    init(block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }

    deinit {
        for (object, address) in added {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    func add(_ address: AudioObjectPropertyAddress, on object: AudioObjectID) {
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return }
        added.append((object, address))
    }
}
#endif
