import XCTest

/// The platform seam as source lints (contracts §7 S0-K, core-sharing
/// P0.3). Shared code imports no UI framework, names none of its types and
/// never branches on the platform. Only these may:
/// - Platform/, the seam itself;
/// - the three reader files that hold both TextKit hosts' halves;
/// - the iOS-only files in `MacExclusions`, for imports and types (they
///   never need a platform branch);
/// - the Mac's own ios/AloudMac.
/// And nothing the Mac compiles touches TextKit 1.
///
/// The rules read each file's code view (`SwiftLiterals.code(in:)`), so a
/// comment or a string that mentions UIKit never trips them. Pure source
/// reads over ios/Aloud, and ios/AloudMac once it exists. Skips when the
/// host can't see the checkout. A failure lists each offender as
/// `path:line «code»`.
final class PlatformBoundaryLintTests: XCTestCase {

    /// The seam: its files hold each platform's half.
    private static let seam = "Platform/"

    /// The reader's shared TextKit 2 core. Each platform's half sits behind
    /// a platform condition here (contracts §1 rule 5).
    private static let readerHalves: Set<String> = [
        "Reader/ReaderColumnText.swift", "Reader/ReaderColumnLayout.swift", "Reader/HighlightLayers.swift",
    ]

    /// `import UIKit`, `@preconcurrency import AppKit`, `internal import
    /// UIKit`, `import class UIKit.UIImage`. Cocoa brings AppKit along.
    private static let frameworkImport =
        #"^\s*(@\w+(\([^)]*\))?\s+)*((public|package|internal|fileprivate|private)\s+)?import\s+((class|struct|enum|protocol|typealias|func|var|let)\s+)?(UIKit|AppKit|Cocoa)\b"#

    /// A compilation condition that picks a platform: `os(…)`, or the UI
    /// framework only one platform has (`canImport(UIKit)` reads as
    /// `os(iOS)` does).
    private static let platformCondition =
        #"^\s*#(if|elseif)\b.*(\bos\(|\bcanImport\(\s*(UIKit|AppKit|Cocoa)\b|\btargetEnvironment\(\s*macCatalyst\b)"#

    /// UI framework types a file can reach with no import of its own,
    /// because `import SwiftUI` brings UIKit along on iOS and AppKit on the
    /// Mac. Every UIKit type, and AppKit's common ones; the app's own
    /// `UITest…` names are not UIKit's.
    private static let frameworkTypes = [
        #"\bUI(?!Test)[A-Z]\w*"#,
        #"\bNS(Application|App|Color|Font|FontDescriptor|Image|BitmapImageRep|View|ViewController|Window|Screen|Workspace|BezierPath|Appearance|Event|Menu|MenuItem|Pasteboard|TextView|ScrollView|HostingView|HostingController|ViewRepresentable|Accessibility|Responder|Cursor|Alert|OpenPanel|SavePanel|GraphicsContext)\b"#,
    ]

    /// TextKit 1 (its delegate too). Reaching for it silently drops a text
    /// view out of TextKit 2, on UIKit and AppKit alike.
    private static let textKit1 = [#"\.layoutManager\b"#, #"\bNSLayoutManager"#]

    // MARK: - The rules' reach

    func testTheRulesReach() throws {
        let imports = ["import UIKit", "@preconcurrency import AppKit", "    import class UIKit.UIImage",
                       "@_exported import Cocoa", "internal import UIKit", "@preconcurrency public import AppKit"]
        let notImports = ["import SwiftUI", "import UIKitty", "let imported = UIKit"]
        try assertReach([Self.frameworkImport], hits: imports, misses: notImports)

        let conditions = ["#if os(iOS)", "    #elseif os(macOS)", "#if !os(macOS)", "#if DEBUG && os(iOS)",
                          "#if canImport(UIKit)", "#elseif canImport(AppKit)", "#if targetEnvironment(macCatalyst)"]
        let notConditions = ["#if DEBUG", "#else", "#endif", "#if canImport(AppIntents)",
                             "if #available(iOS 17, *) {", "let os = 1"]
        try assertReach([Self.platformCondition], hits: conditions, misses: notConditions)

        let types = ["UIApplication.shared.applicationState", "let color: UIColor", "NSApp?.isActive",
                     "NSColor(name: nil)", "UIAccessibility.post(", "NSWorkspace.shared"]
        let notTypes = ["UITestHooks.fault", "UITestAnnouncementLog.shared", "NSAttributedString(string: s)",
                        "NSTextLayoutManager", "NSRange(location: 0, length: 1)", "NSCache<NSString, PlatformImage>"]
        try assertReach(Self.frameworkTypes, hits: types, misses: notTypes)

        let textKit1 = ["textView.layoutManager", "container.layoutManager?.glyphRange", "NSLayoutManager()",
                        "extension Coordinator: NSLayoutManagerDelegate"]
        let textKit2 = ["textView.textLayoutManager", "let manager: NSTextLayoutManager",
                        "ReaderColumnLayout(textLayoutManager: manager", "NSTextLayoutManagerDelegate"]
        try assertReach(Self.textKit1, hits: textKit1, misses: textKit2)
    }

    /// The code view keeps a guard's scope: a branch of a platform condition
    /// (its `#else` too) is guarded, a DEBUG-only branch is not.
    func testCodeLinesKnowTheirPlatformGuard() throws {
        let source = """
            import SwiftUI
            #if os(iOS)
            import UIKit
            #else
            import AppKit
            #endif
            #if DEBUG
            import UIKit // a comment
            #elseif canImport(UIKit)
            import UIKit
            #endif
            """
        let lines = try Self.codeLines(of: ["F.swift": source])
        let guarded = lines.filter { $0.text.hasPrefix("import") }.map { "\($0.number):\($0.platformGuarded)" }
        XCTAssertEqual(guarded, ["1:false", "3:true", "5:true", "8:false", "10:true"])
        XCTAssertEqual(lines[7].text, "import UIKit ", "the code view drops the comment")
    }

    // MARK: - The exclusion list

    /// The 14 iOS-only files are real files, named once, and none is part of
    /// the seam; nothing Swift hides under Resources, which the Mac leaves
    /// out whole.
    func testMacExclusionsAreTheFourteenIOSOnlyFiles() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(MacExclusions.swiftFiles.count, 14)
        XCTAssertEqual(Set(MacExclusions.swiftFiles).count, MacExclusions.swiftFiles.count, "an entry is repeated")
        XCTAssertEqual(MacExclusions.swiftFiles.filter { sources[$0] == nil }, [],
                       "an excluded file moved or was renamed; update MacExclusions and project.yml together")
        XCTAssertEqual(MacExclusions.swiftFiles.filter { $0.hasPrefix(Self.seam) || Self.readerHalves.contains($0) },
                       [], "the seam and the reader halves are shared")
        XCTAssertEqual(MacExclusions.nonSwift, ["Info.plist", "Resources/**"])
        XCTAssertEqual(MacExclusions.projectExcludes, MacExclusions.nonSwift + MacExclusions.swiftFiles)
        XCTAssertEqual(sources.keys.filter { $0.hasPrefix("Resources/") }.sorted(), [],
                       "Swift under Resources/ would be left out of the Mac without a word")
        XCTAssertTrue(MacExclusions.excludes("Reader/ReaderTextView.swift"))
        XCTAssertFalse(MacExclusions.excludes("Reader/ReaderColumnLayout.swift"))
    }

    // MARK: - (i) Imports and types

    /// No shared file imports UIKit or AppKit. The seam and the reader
    /// halves may, each behind its platform's condition, because the Mac
    /// compiles them too. The iOS-only files and the Mac's own may freely.
    func testOnlyTheSeamImportsAUIFramework() throws {
        let lines = try Self.codeLines(of: SourceTree.appSources())
        let imports = try Self.lines(lines, matching: [Self.frameworkImport])
        assertNone(imports.filter { Self.isShared($0.path) },
                   "Shared code imports no UI framework; a call goes through Platform/")
        assertNone(imports.filter { Self.holdsHalves($0.path) && !$0.platformGuarded },
                   "A file both apps compile imports a UI framework only behind its platform's #if")
        XCTAssertTrue(imports.contains { $0.path.hasPrefix(Self.seam) && $0.platformGuarded },
                      "the scan sees the seam's own imports, so an empty result above means something")
    }

    /// `import SwiftUI` already brings the platform's UI framework along, so
    /// no import line is no proof: no shared file names a UIKit or AppKit
    /// type either.
    func testSharedCodeNamesNoUIFrameworkType() throws {
        let lines = try Self.codeLines(of: SourceTree.appSources())
        let named = try Self.lines(lines, matching: Self.frameworkTypes)
        assertNone(named.filter { Self.isShared($0.path) },
                   "Shared code names no UIKit or AppKit type; the seam in Platform/ does")
        XCTAssertTrue(named.contains { $0.path.hasPrefix(Self.seam) },
                      "the scan sees the seam's own types, so an empty result above means something")
    }

    // MARK: - (ii) Platform branches

    /// Only the seam, the reader halves and the Mac's own files branch on
    /// the platform. The iOS-only files have no other platform to branch
    /// to.
    func testOnlyTheSeamBranchesOnThePlatform() throws {
        let lines = try Self.codeLines(of: SourceTree.appSources())
        let branches = try Self.lines(lines, matching: [Self.platformCondition])
        assertNone(branches.filter { !Self.holdsHalves($0.path) && !$0.path.hasPrefix(SourceTree.macPrefix) },
                   "A platform #if lives in Platform/ or the three reader halves")
        XCTAssertTrue(branches.contains { $0.path.hasPrefix(Self.seam) },
                      "the scan sees the seam's own branches, so an empty result above means something")
    }

    // MARK: - (iii) TextKit 2

    /// What the Mac compiles reads text only through `textLayoutManager` and
    /// `textContentManager`: the shared reader files, every other shared
    /// file, and the Mac's own. (The iPhone's UIKit wrapper is its own.)
    func testMacCompiledCodeStaysOnTextKit2() throws {
        let sources = try SourceTree.macCompiledSources(excluding: MacExclusions.projectExcludes)
        XCTAssertNotNil(sources["Reader/ReaderColumnLayout.swift"], "the scan reads the shared reader")
        XCTAssertNil(sources["Reader/ReaderTextView.swift"], "the iPhone's wrapper is not shared")
        let textKit1 = try Self.lines(Self.codeLines(of: sources), matching: Self.textKit1)
        assertNone(textKit1, "TextKit 1 drops the column out of TextKit 2; use ReaderColumnLayout")
    }

    // MARK: - Helpers

    /// One line of a file's code view.
    private struct CodeLine: CustomStringConvertible {
        let path: String
        /// 1-based.
        let number: Int
        let text: String
        /// Inside a branch that picks a platform: `#if os(iOS)`, its
        /// `#else`, `#elseif canImport(AppKit)` and so on.
        let platformGuarded: Bool

        var description: String {
            "\(path):\(number) \u{00AB}\(text.trimmingCharacters(in: .whitespaces))\u{00BB}"
        }
    }

    /// A file both apps compile, outside the seam: not Platform/, a reader
    /// half, an iOS-only file or a Mac file.
    private static func isShared(_ path: String) -> Bool {
        !holdsHalves(path) && !MacExclusions.excludes(path) && !path.hasPrefix(SourceTree.macPrefix)
    }

    /// A shared file that holds each platform's half behind a condition.
    private static func holdsHalves(_ path: String) -> Bool {
        path.hasPrefix(seam) || readerHalves.contains(path)
    }

    /// Every line of every file in `sources`, as code (comments gone,
    /// literal text blanked), in path then line order, each with whether a
    /// platform condition guards it.
    private static func codeLines(of sources: [String: String]) throws -> [CodeLine] {
        let condition = try NSRegularExpression(pattern: platformCondition)
        var lines: [CodeLine] = []
        for path in sources.keys.sorted() {
            // One entry per open #if: whether its current branch picks a
            // platform. Once one does, every later branch of that #if is
            // the other platforms' (an #else included).
            var open: [Bool] = []
            let code = SwiftLiterals.code(in: sources[path] ?? "")
            for (index, text) in code.components(separatedBy: "\n").enumerated() {
                lines.append(CodeLine(path: path, number: index + 1, text: text, platformGuarded: open.contains(true)))
                let directive = text.trimmingCharacters(in: .whitespaces)
                guard directive.hasPrefix("#") else { continue }
                let picks = matches(condition, text)
                switch directive.dropFirst().prefix(while: \.isLetter) {
                case "if": open.append(picks)
                case "elseif": if let last = open.popLast() { open.append(last || picks) }
                case "endif": _ = open.popLast()
                default: break
                }
            }
        }
        return lines
    }

    /// The lines that match any of `patterns`.
    private static func lines(_ lines: [CodeLine], matching patterns: [String]) throws -> [CodeLine] {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        return lines.filter { line in regexes.contains { matches($0, line.text) } }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func assertReach(_ patterns: [String], hits: [String], misses: [String],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        for text in hits {
            XCTAssertTrue(regexes.contains { Self.matches($0, text) }, "the lint misses \(text)", file: file, line: line)
        }
        for text in misses {
            XCTAssertFalse(regexes.contains { Self.matches($0, text) }, "the lint flags \(text)", file: file, line: line)
        }
    }

    private func assertNone(_ hits: [CodeLine], _ rule: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hits.isEmpty, "\(rule):\n" + hits.map(\.description).joined(separator: "\n"),
                      file: file, line: line)
    }
}
