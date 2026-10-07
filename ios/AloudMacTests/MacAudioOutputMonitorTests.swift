import AVFoundation
import CoreAudio
import XCTest
@testable import Aloud

/// S7 on the Mac: `MacAudioOutputMonitor` classifies devices through the HAL
/// it is given and acts on `OutputRoutePolicy`. A fake HAL stands in for
/// CoreAudio, so nothing here touches a real device: the engines are never
/// started, and the fake's bind only records.
@MainActor
final class MacAudioOutputMonitorTests: XCTestCase {

    // Device IDs as the fake HAL reports them.
    private let speakers: AudioObjectID = 41
    private let airPods: AudioObjectID = 73
    private let usbDAC: AudioObjectID = 88

    private var hal: FakeHAL!
    private var monitor: MacAudioOutputMonitor!
    private var pauses = 0

    override func setUp() async throws {
        hal = FakeHAL()
        hal.add(speakers, transport: "bltn", dataSource: "ispk")
        hal.add(airPods, transport: "blue")
        hal.add(usbDAC, transport: "usb ")
        hal.defaultOutputDevice = airPods
        monitor = MacAudioOutputMonitor(hardware: hal, settleInterval: 0)
        pauses = 0
        monitor.onRouteRequiresPause = { [unowned self] in pauses += 1 }
    }

    // MARK: - Classification

    func testDevicesAreClassifiedThroughTheHAL() {
        XCTAssertEqual(monitor.device(airPods), OutputDevice(id: airPods, transport: .bluetooth, dataSource: nil))
        XCTAssertEqual(monitor.device(speakers),
                       OutputDevice(id: speakers, transport: .builtIn, dataSource: .speakers))
        XCTAssertEqual(monitor.device(usbDAC).transport, .usb)
        hal.dataSources[speakers] = code("hdpn")
        XCTAssertEqual(monitor.device(speakers).dataSource, .headphones)
        XCTAssertEqual(monitor.device(999).transport, .unknown, "a device the HAL can't read")
    }

    // MARK: - Binding

    /// Play pins the engine to the default output and watches that device.
    func testBindPinsTheEngineToTheDefaultOutput() {
        let engine = AVAudioEngine()
        monitor.bindOutput(of: engine)
        XCTAssertEqual(hal.boundDevices, [airPods])
        XCTAssertEqual(hal.watchedDevices, [airPods])
        XCTAssertEqual(monitor.bound, OutputDevice(id: airPods, transport: .bluetooth, dataSource: nil))
    }

    /// Offline there is no device to pin.
    func testOfflineEnginesAreNeverBound() throws {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        monitor.bindOutput(of: engine)
        XCTAssertEqual(hal.boundDevices, [])
        XCTAssertNil(monitor.bound)
    }

    // MARK: - Decisions

    /// Before anything is bound, no change means anything.
    func testNothingBoundIgnoresEveryChange() {
        hal.defaultOutputDevice = speakers
        hal.fire()
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .ignore)
    }

    /// AirPods run flat: private to public, so playback pauses rather than
    /// moving to the speakers.
    func testPrivateToPublicPauses() {
        monitor.bindOutput(of: AVAudioEngine())
        hal.remove(airPods)
        hal.defaultOutputDevice = speakers
        hal.fire()
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .stop(.headphonesDisconnected),
                       "the engine's own change still reads as the stop, so nothing queued plays on")
    }

    /// A device that reports itself dead counts as gone, even while listed.
    func testADeadDevicePauses() {
        monitor.bindOutput(of: AVAudioEngine())
        hal.alive[airPods] = false
        hal.fire()
        XCTAssertEqual(pauses, 1)
    }

    /// Wired headphones pulled from the built-in jack: the same device, now
    /// on its speakers.
    func testJackToSpeakersPausesOnceAndThenLetsPlayStay() {
        hal.dataSources[speakers] = code("hdpn")
        hal.defaultOutputDevice = speakers
        monitor.bindOutput(of: AVAudioEngine())

        hal.dataSources[speakers] = code("ispk")
        hal.fire()
        XCTAssertEqual(pauses, 1)

        // The listener presses Play on the speakers: a later change on the
        // same output doesn't stop it again.
        hal.fire()
        XCTAssertEqual(pauses, 1)
        XCTAssertNotEqual(monitor.decisionAfterConfigurationChange(), .stop(.headphonesDisconnected))
    }

    /// The listener picks another output while the old one is still there:
    /// follow, with no pause.
    func testTheListenersOwnSwitchIsFollowed() {
        monitor.bindOutput(of: AVAudioEngine())
        hal.defaultOutputDevice = usbDAC
        hal.fire()
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .follow)
    }

    /// A stopped engine binds afresh at the next Play, so a followed switch
    /// posts no configuration change for it.
    func testAFollowedSwitchLeavesAStoppedEngineAlone() {
        let engine = AVAudioEngine()
        monitor.bindOutput(of: engine)
        let posted = expectation(forNotification: .AVAudioEngineConfigurationChange, object: engine)
        posted.isInverted = true
        hal.defaultOutputDevice = usbDAC
        hal.fire()
        wait(for: [posted], timeout: 0.2)
    }

    /// AirPods gone, reported first as the speakers becoming the default
    /// while the AirPods are still listed: the switch settles before it is
    /// followed, and by then it reads as the stop it is.
    func testASwitchThatTurnsOutToBeAVanishedDevicePauses() {
        let settling = MacAudioOutputMonitor(hardware: hal, settleInterval: 0.05)
        var settledPauses = 0
        settling.onRouteRequiresPause = { settledPauses += 1 }
        settling.bindOutput(of: AVAudioEngine())

        hal.defaultOutputDevice = speakers
        hal.fire()
        hal.fire()   // more listeners for the same change
        XCTAssertEqual(settledPauses, 0, "nothing acted on before the HAL settles")
        hal.remove(airPods)
        spinRunLoop(0.3)
        XCTAssertEqual(settledPauses, 1, "the vanished AirPods pause once, never follow to the speakers")
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .stop(.headphonesDisconnected))
    }

    /// A switch the listener made, still standing once settled, is followed
    /// with no pause.
    func testASettledSwitchIsStillFollowed() {
        let settling = MacAudioOutputMonitor(hardware: hal, settleInterval: 0.05)
        var settledPauses = 0
        settling.onRouteRequiresPause = { settledPauses += 1 }
        settling.bindOutput(of: AVAudioEngine())

        hal.defaultOutputDevice = usbDAC
        hal.fire()
        spinRunLoop(0.3)
        XCTAssertEqual(settledPauses, 0)
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .follow)
    }

    /// The engine's own change can arrive while departing AirPods are still
    /// listed and the speakers already the default. It waits for the HAL to
    /// settle as a listener's change does, and by then reads as the stop it
    /// is: speech never follows to the speakers.
    func testAnEngineChangeWhileAirPodsLeaveNeverFollowsToTheSpeakers() {
        let settling = MacAudioOutputMonitor(hardware: hal, settleInterval: 0.05)
        var settledPauses = 0
        settling.onRouteRequiresPause = { settledPauses += 1 }
        let engine = AVAudioEngine()
        settling.bindOutput(of: engine)
        let posted = expectation(forNotification: .AVAudioEngineConfigurationChange, object: engine)
        posted.isInverted = true

        hal.defaultOutputDevice = speakers
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .ignore, "nothing acted on before the HAL settles")
        hal.remove(airPods)
        wait(for: [posted], timeout: 0.3)
        XCTAssertEqual(settledPauses, 1, "the vanished AirPods pause, never follow to the speakers")
        XCTAssertEqual(hal.boundDevices, [airPods], "nothing rebinds to the speakers")
        withExtendedLifetime(engine) {}
    }

    /// The listener's own switch reached first through the engine's change
    /// (the engine stopped itself): once settled, the change is posted again
    /// for the stopped engine, and followed.
    func testAnEngineChangeOntoTheListenersSwitchIsFollowedOnceSettled() {
        let settling = MacAudioOutputMonitor(hardware: hal, settleInterval: 0.05)
        var settledPauses = 0
        settling.onRouteRequiresPause = { settledPauses += 1 }
        let engine = AVAudioEngine()   // never started, as after it stopped itself
        settling.bindOutput(of: engine)
        let posted = expectation(forNotification: .AVAudioEngineConfigurationChange, object: engine)

        hal.defaultOutputDevice = usbDAC
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .ignore, "not before the HAL settles")
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .follow, "the settled change is followed")
        XCTAssertEqual(settledPauses, 0)
        withExtendedLifetime(engine) {}
    }

    /// A format change on the bound device has nothing to fall through to:
    /// followed at once, even with a settle.
    func testAFormatChangeOnTheBoundDeviceIsFollowedAtOnce() {
        let settling = MacAudioOutputMonitor(hardware: hal, settleInterval: 0.05)
        let engine = AVAudioEngine()
        settling.bindOutput(of: engine)
        XCTAssertEqual(settling.decisionAfterConfigurationChange(), .follow)
        withExtendedLifetime(engine) {}
    }

    // MARK: - S8 · the route-lost fault

    func testSimulatedPrivateToPublicPauses() {
        monitor.bindOutput(of: AVAudioEngine())
        monitor.simulate(.privateToPublic)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(hal.boundDevices, [airPods], "no hardware touched beyond the bind")
    }

    /// A muted process never binds, and the fault still pauses it.
    func testSimulatedPrivateToPublicPausesWithNothingBound() {
        monitor.simulate(.privateToPublic)
        XCTAssertEqual(pauses, 1)
    }

    /// The fault reaches the monitor the app built.
    func testTheFaultGoesThroughTheLiveMonitor() {
        XCTAssertTrue(MacAudioOutputMonitor.current === monitor)
        AudioOutputFaults.post(.routeLost)
        XCTAssertEqual(pauses, 1)
    }

    /// No session to claim and no interruptions on a Mac.
    func testSessionCallsDoNothing() throws {
        var interruptions = 0
        monitor.onInterruption = { _ in interruptions += 1 }
        try monitor.activate()
        monitor.deactivate(notifyingOthers: true)
        XCTAssertEqual(interruptions, 0)
        XCTAssertTrue(PlatformAudioOutput.makeMonitor() is MacAudioOutputMonitor)
    }

    // MARK: - Helpers

    private func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// CoreAudio as the monitor reads it, held in dictionaries.
@MainActor
private final class FakeHAL: AudioHardwareReading {

    var onChange: (@MainActor () -> Void)?
    var defaultOutputDevice: AudioObjectID?
    private(set) var devices: [AudioObjectID] = []
    var alive: [AudioObjectID: Bool] = [:]
    var transports: [AudioObjectID: UInt32] = [:]
    var dataSources: [AudioObjectID: UInt32] = [:]
    private(set) var watchedDevices: [AudioObjectID] = []
    private(set) var boundDevices: [AudioObjectID] = []

    func add(_ device: AudioObjectID, transport: String, dataSource: String? = nil) {
        devices.append(device)
        alive[device] = true
        transports[device] = code(transport)
        dataSources[device] = dataSource.map(code)
    }

    func remove(_ device: AudioObjectID) {
        devices.removeAll { $0 == device }
        alive[device] = nil
    }

    /// A listener fires, as the HAL's would on the main queue.
    func fire() {
        onChange?()
    }

    func isAlive(_ device: AudioObjectID) -> Bool { alive[device] ?? false }
    func transportType(of device: AudioObjectID) -> UInt32? { transports[device] }
    func dataSource(of device: AudioObjectID) -> UInt32? { dataSources[device] }
    func watch(device: AudioObjectID) { watchedDevices.append(device) }
    func bind(_ engine: AVAudioEngine, to device: AudioObjectID) { boundDevices.append(device) }

    private func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
