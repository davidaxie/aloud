import AppKit
import XCTest
@testable import Aloud

/// About Aloud (M20, mac-ux §3.12): the Credits carry every line of the
/// Licenses page, so each bundled component and the classics' source are
/// credited, legibly in either appearance, and the panel names the app's
/// version.
@MainActor
final class MacAboutCreditsTests: XCTestCase {

    func testEveryLicensesEntryIsCredited() {
        let credits = MacAboutCredits.credits().string
        XCTAssertFalse(LicensesView.entries.isEmpty)
        for entry in LicensesView.entries {
            XCTAssertTrue(credits.contains(entry.id), entry.id)
            XCTAssertTrue(credits.contains(entry.license), "\(entry.id)'s license")
            XCTAssertTrue(credits.contains(entry.detail), "\(entry.id)'s note")
        }
        for line in [LicensesView.intro, LicensesView.classicsTitle, LicensesView.classicsNote] {
            XCTAssertTrue(credits.contains(line), line)
        }
    }

    /// What the app owes credit for, each with its license.
    func testTheRequiredAttributionsAppear() {
        let credits = MacAboutCredits.credits().string
        let owed = [("Kokoro", "Apache License 2.0"), ("sherpa-onnx", "Apache License 2.0"),
                    ("ONNX Runtime", "MIT License"), ("espeak-ng", "GPL-3.0")]
        for (name, license) in owed {
            let entry = LicensesView.entries.first { $0.id.hasPrefix(name) }
            XCTAssertEqual(entry?.license, license, name)
            XCTAssertTrue(credits.contains(name), name)
        }
        XCTAssertTrue(credits.contains("Project Gutenberg"))
        XCTAssertTrue(credits.contains("gutenberg.org"))
    }

    /// R2-20: each component's source follows its note as a link, as the
    /// Licenses page's source row is: footnote size, the system link color.
    func testEachComponentsSourceIsALink() throws {
        let credits = MacAboutCredits.credits()
        let text = credits.string as NSString
        for entry in LicensesView.entries {
            let line = LicensesCopy.source(entry.source)
            let range = text.range(of: line)
            XCTAssertNotEqual(range.location, NSNotFound, "\(entry.id)'s source")
            guard range.location != NSNotFound else { continue }
            let link = credits.attribute(.link, at: range.location, effectiveRange: nil)
            XCTAssertEqual((link as? URL) ?? (link as? String).flatMap(URL.init(string:)), entry.source, entry.id)
            XCTAssertEqual(credits.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
                           .linkColor, entry.id)
            let font = try XCTUnwrap(credits.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, PlatformTypeRamp.basePoints(.footnote), entry.id)
            let detail = text.range(of: entry.detail)
            XCTAssertLessThan(detail.location, range.location, "\(entry.id): the note, then its source")
        }
        let classics = text.range(of: LicensesView.classicsNote)
        XCTAssertNil(credits.attribute(.link, at: classics.location, effectiveRange: nil), "only the sources link")
    }

    /// Not empty, no blank paragraph, and every run set: a run with no color
    /// stays black on the panel in Dark Mode.
    func testCreditsAreNotEmptyAndEveryRunIsSet() {
        let credits = MacAboutCredits.credits()
        XCTAssertFalse(credits.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(credits.string.hasSuffix("\n"))
        XCTAssertFalse(credits.string.contains("\n\n"), "no empty paragraph")
        credits.enumerateAttributes(in: NSRange(location: 0, length: credits.length)) { attributes, range, _ in
            XCTAssertNotNil(attributes[.font] as? NSFont, "\(range)")
            XCTAssertNotNil(attributes[.foregroundColor] as? NSColor, "\(range)")
            XCTAssertEqual((attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment, .center, "\(range)")
        }
    }

    /// The Licenses page's weights at the Mac ramp's sizes.
    func testCreditsUseTheMacRamp() throws {
        let credits = MacAboutCredits.credits()
        let text = credits.string as NSString
        func font(of line: String) throws -> NSFont {
            let range = text.range(of: line)
            XCTAssertNotEqual(range.location, NSNotFound, line)
            return try XCTUnwrap(credits.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont, line)
        }
        let entry = try XCTUnwrap(LicensesView.entries.first)
        XCTAssertEqual(try font(of: entry.id).pointSize, PlatformTypeRamp.basePoints(.body))
        XCTAssertEqual(try font(of: entry.license).pointSize, PlatformTypeRamp.basePoints(.caption))
        XCTAssertEqual(try font(of: LicensesView.classicsNote).pointSize, PlatformTypeRamp.basePoints(.footnote))
    }

    func testThePanelShowsTheCreditsAndTheAppsVersion() throws {
        XCTAssertEqual(MacAboutCredits.menuTitle, "About Aloud")
        let options = MacAboutCredits.options()
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertEqual(credits.string, MacAboutCredits.credits().string)

        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                    "the host is Aloud")
        XCTAssertEqual(options[.applicationVersion] as? String, version)
        XCTAssertEqual(options[.version] as? String,
                       Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
