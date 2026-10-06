import XCTest

/// The built app as App Store Connect reads it, on both hosts: a version
/// and a build in its Info.plist, and its privacy manifest among its
/// resources. A target missing MARKETING_VERSION once built an iPhone app
/// with neither key, whatever Aloud/Info.plist said, and an upload is
/// refused for either gap. Reads only the host app's own bundle.
final class ShippedBundleTests: XCTestCase {

    func testTheAppCarriesItsVersionAndBuild() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        XCTAssertNotNil(version.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression),
                        "CFBundleShortVersionString '\(version)'")
        XCTAssertNotNil(build.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression),
                        "CFBundleVersion '\(build)'")
    }

    func testThePrivacyManifestShips() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "no PrivacyInfo.xcprivacy in \(Bundle.main.bundleURL.lastPathComponent)")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                                             format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let declared = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertTrue(declared.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "\(declared)")
        #if os(macOS)
        XCTAssertTrue(declared.contains("NSPrivacyAccessedAPICategorySystemBootTime"), "the Mac's own manifest")
        #else
        XCTAssertFalse(declared.contains("NSPrivacyAccessedAPICategorySystemBootTime"), "the iPhone's own manifest")
        #endif
    }
}
