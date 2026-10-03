import Combine
import XCTest
@testable import Aloud

/// M19's memory-pressure levels, as shared code sees them on both hosts:
/// the level a warning carries (the Mac's relay names it; the iPhone's
/// single warning carries none and reads as critical, as it always freed),
/// and which engines each level frees. The pre-warm acting on them is
/// NeuralPrewarmTests here and MacPowerTests on the Mac.
///
/// Pure: no engine, no relay and no kernel source; warnings go to a
/// private center.
final class MemoryPressureTests: XCTestCase {

    private typealias Pressure = PlatformLifecycle.MemoryPressure

    func testTheKernelsLevels() {
        XCTAssertEqual(Pressure(.warning), .warning)
        XCTAssertEqual(Pressure(.critical), .critical)
        XCTAssertEqual(Pressure([.warning, .critical]), .critical, "the harder level wins")
        XCTAssertNil(Pressure(.normal), "pressure eased: nothing to free")
        XCTAssertNil(Pressure([]))
    }

    /// Each level survives the trip through a posted warning, as the
    /// observers receive it.
    func testAWarningCarriesItsLevel() {
        let center = NotificationCenter()
        var received: [Pressure] = []
        let subscription = PlatformLifecycle.publisher(for: .memoryWarning, in: center)
            .sink { received.append(Pressure(of: $0)) }
        for pressure in Pressure.allCases {
            PlatformLifecycle.post(.memoryWarning, to: center, pressure: pressure)
        }
        subscription.cancel()
        XCTAssertEqual(received, [.warning, .critical])
    }

    /// The iPhone's `didReceiveMemoryWarning` carries no level: critical,
    /// so it frees a paused engine exactly as before levels existed. So
    /// does anything that isn't a level.
    func testAWarningWithoutALevelIsCritical() {
        let name = PlatformLifecycle.Event.memoryWarning.name
        XCTAssertEqual(Pressure(of: Notification(name: name)), .critical)
        XCTAssertEqual(Pressure(of: Notification(name: name, object: nil,
                                                 userInfo: [Pressure.userInfoKey: "severe"])), .critical)
        XCTAssertEqual(Pressure(of: Notification(name: name, object: nil,
                                                 userInfo: [Pressure.userInfoKey: 1])), .critical)
    }

    /// Never a reading engine; one nothing waits on at either level; a
    /// paused one only at critical.
    func testWhichEnginesEachLevelFrees() {
        let statuses: [PlayerStatus] = [.idle, .buffering, .playing, .paused, .ended, .error]
        for status in statuses {
            for pressure in Pressure.allCases {
                let expected: Bool
                switch status {
                case .playing, .buffering: expected = false
                case .paused: expected = pressure == .critical
                case .idle, .ended, .error: expected = true
                }
                XCTAssertEqual(NeuralPrewarm.releasesEngine(under: pressure, status: status), expected,
                               "\(status) at \(pressure)")
            }
        }
        XCTAssertTrue(NeuralPrewarm.releasesEngine(under: Pressure(of: Notification(name: .init("x"))),
                                                   status: .paused),
                      "the iPhone's warning frees a paused engine, as it always has")
    }
}
