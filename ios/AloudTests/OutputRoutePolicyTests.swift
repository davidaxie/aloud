import XCTest
@testable import Aloud

/// M12's headphones table, pure, so the iPhone's suite pins the rule the
/// Mac's audio monitor follows: speech never falls through to the speakers.
final class OutputRoutePolicyTests: XCTestCase {

    private let speakers = OutputDevice(id: 40, transport: .builtIn, dataSource: .speakers)
    private let jack = OutputDevice(id: 40, transport: .builtIn, dataSource: .headphones)
    private let airPods = OutputDevice(id: 51, transport: .bluetooth, dataSource: nil)
    private let usbDAC = OutputDevice(id: 62, transport: .usb, dataSource: nil)
    private let display = OutputDevice(id: 73, transport: .hdmi, dataSource: nil)

    // MARK: The M12 table

    func testBluetoothRemovedStops() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: airPods, current: speakers, previousStillPresent: false),
                       .stop(.headphonesDisconnected))
    }

    func testUSBDACRemovedStops() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: usbDAC, current: speakers, previousStillPresent: false),
                       .stop(.headphonesDisconnected))
    }

    func testJackToSpeakersStops() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: jack, current: speakers, previousStillPresent: true),
                       .stop(.headphonesDisconnected))
    }

    func testUserSwitchWithTheOldDevicePresentFollows() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: airPods, current: speakers, previousStillPresent: true),
                       .follow)
        XCTAssertEqual(OutputRoutePolicy.decide(previous: speakers, current: usbDAC, previousStillPresent: true),
                       .follow)
    }

    func testSampleRateChangeFollows() {
        // Same device, same source: only the format moved under the engine.
        for device in [speakers, jack, airPods, usbDAC] {
            XCTAssertEqual(OutputRoutePolicy.decide(previous: device, current: device, previousStillPresent: true),
                           .follow, "\(device.transport)")
        }
    }

    // MARK: Edges

    func testAnyVanishedDeviceStopsWhateverIsLeft() {
        // An unplugged display's audio would land on the speakers too.
        XCTAssertEqual(OutputRoutePolicy.decide(previous: display, current: speakers, previousStillPresent: false),
                       .stop(.headphonesDisconnected))
        XCTAssertEqual(OutputRoutePolicy.decide(previous: airPods, current: nil, previousStillPresent: false),
                       .stop(.headphonesDisconnected))
    }

    func testHeadphonesPluggedIntoTheJackFollow() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: speakers, current: jack, previousStillPresent: true),
                       .follow)
    }

    func testJackToAnUnreadableSourceStops() {
        // Can't tell where the sound went: the safe answer is silence.
        let unreadable = OutputDevice(id: 40, transport: .builtIn, dataSource: nil)
        XCTAssertEqual(OutputRoutePolicy.decide(previous: jack, current: unreadable, previousStillPresent: true),
                       .stop(.headphonesDisconnected))
    }

    func testNothingBoundIsIgnored() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: nil, current: speakers, previousStillPresent: false),
                       .ignore)
        XCTAssertEqual(OutputRoutePolicy.decide(previous: nil, current: nil, previousStillPresent: true),
                       .ignore)
    }

    func testNoDefaultOutputKeepsTheBoundDevice() {
        XCTAssertEqual(OutputRoutePolicy.decide(previous: airPods, current: nil, previousStillPresent: true),
                       .ignore)
    }

    // MARK: CoreAudio codes

    /// The four-character codes from AudioHardwareBase.h, as numbers, so a
    /// misspelled code can't pass by matching itself.
    func testTransportCodesMatchCoreAudio() {
        let table: [(UInt32, OutputDevice.Transport)] = [
            (0x626C_746E, .builtIn),      // kAudioDeviceTransportTypeBuiltIn 'bltn'
            (0x626C_7565, .bluetooth),    // kAudioDeviceTransportTypeBluetooth 'blue'
            (0x626C_6561, .bluetoothLE),  // kAudioDeviceTransportTypeBluetoothLE 'blea'
            (0x7573_6220, .usb),          // kAudioDeviceTransportTypeUSB 'usb '
            (0x6169_7270, .airPlay),      // kAudioDeviceTransportTypeAirPlay 'airp'
            (0x6864_6D69, .hdmi),         // kAudioDeviceTransportTypeHDMI 'hdmi'
            (0x6470_7274, .displayPort),  // kAudioDeviceTransportTypeDisplayPort 'dprt'
            (0x6772_7570, .aggregate),    // kAudioDeviceTransportTypeAggregate 'grup'
            (0x7669_7274, .virtual),      // kAudioDeviceTransportTypeVirtual 'virt'
            (0x7468_756E, .unknown),      // Thunderbolt 'thun': not one the rule names
            (0, .unknown),
        ]
        for (code, transport) in table {
            XCTAssertEqual(OutputDevice.Transport(code: code), transport, String(code, radix: 16))
        }
    }

    func testDataSourceCodesMatchCoreAudio() {
        XCTAssertEqual(OutputDevice.DataSource(code: 0x6864_706E), .headphones)   // 'hdpn'
        XCTAssertEqual(OutputDevice.DataSource(code: 0x6973_706B), .speakers)     // 'ispk'
        XCTAssertEqual(OutputDevice.DataSource(code: 0x6C69_6E65), .other(0x6C69_6E65))   // 'line'
    }
}
