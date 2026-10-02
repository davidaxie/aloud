import XCTest

/// The lexer under the R25 copy lint (SwiftLiterals). Pure string tests: a
/// lint that misreads Swift either misses copy or fails on a comment, so the
/// lexer's edges are pinned here rather than discovered in CopyLintTests.
final class SwiftLiteralsTests: XCTestCase {

    private func texts(_ source: String) -> [String] {
        SwiftLiterals.literals(in: source).map(\.text)
    }

    // MARK: - Comments

    func testCommentsDocCommentsAndBlockCommentsAreSkipped() {
        let source = ##"""
        // "line comment"
        /// "doc comment"
        /* "block" /* "nested" */ "still in the comment" */
        /**
         "doc block"
         */
        let kept = "kept" // "trailing"
        """##
        XCTAssertEqual(texts(source), ["kept"])
    }

    func testSlashesInsideAStringAreKept() {
        let source = #"let url = "https://huggingface.co/models" // "comment""#
        XCTAssertEqual(texts(source), ["https://huggingface.co/models"])
    }

    // MARK: - Strings

    func testEscapedQuotesStayAsWritten() {
        let source = #"let s = "She said \"hi\" and \\ left""#
        XCTAssertEqual(texts(source), [#"She said \"hi\" and \\ left"#])
        XCTAssertEqual(SwiftLiterals.unescaped(#"She said \"hi\" and \\ left"#), #"She said "hi" and \ left"#)
    }

    func testNestedInterpolationIsOneLiteral() {
        let source = #"Text("\(count) book\(count == 1 ? "" : "s") on \(shelf.name(for: "x(y)"))")"#
        XCTAssertEqual(SwiftLiterals.literals(in: source, path: "Library/Shelf.swift"),
                       [SwiftLiteral(path: "Library/Shelf.swift", line: 1, text: "{expr} book{expr} on {expr}")])
    }

    func testRawAndMultilineLiterals() {
        let source = ###"""
        let raw = #"He said "hi" \n"#
        let interpolated = #"Total: \#(count) items, \(not) one"#
        let multi = """
            First line
              Indented "quote"
            Last \(name)
            """
        let rawMulti = #"""
            Keep \(this) and \#(that)
            """#
        """###
        let literals = SwiftLiterals.literals(in: source)
        XCTAssertEqual(literals.map(\.text), [
            #"He said "hi" \n"#,
            #"Total: {expr} items, \(not) one"#,
            "First line\n  Indented \"quote\"\nLast {expr}",
            #"Keep \(this) and {expr}"#,
        ])
        XCTAssertEqual(literals.map(\.line), [1, 2, 3, 8])
    }

    func testRegexLiteralsGiveNoLiteral() {
        let source = ##"""
        let extended = #/"(\d+)"/#
        let fenced = ##/a"/#b/##
        let bare = /M{0,3}"x/
        let ratio = width / height / 2
        let hash = "#/kept/#"
        let after = "after"
        """##
        XCTAssertEqual(texts(source), ["#/kept/#", "after"])
    }

    func testLineNumbersCountFromTheOpeningQuote() {
        let source = #"""
        /* a block
           comment */ let a = "one"
        let b = "two"; let c = "three"
        let multi = """
            spans
            lines
            """
        let d = "after \(x)"
        """#
        let literals = SwiftLiterals.literals(in: source)
        XCTAssertEqual(literals.map(\.text), ["one", "two", "three", "spans\nlines", "after {expr}"])
        XCTAssertEqual(literals.map(\.line), [2, 3, 3, 4, 8])
    }

    func testUnescapedResolvesUnicodeEscapes() {
        XCTAssertEqual(SwiftLiterals.unescaped(#"Preparing voice\u{2026}"#), "Preparing voice\u{2026}")
        XCTAssertEqual(SwiftLiterals.unescaped(#"Couldn\u{2019}t"#), "Couldn\u{2019}t")
        XCTAssertEqual(SwiftLiterals.unescaped("{expr} left"), "{expr} left")
    }

    // MARK: - Trees

    func testTreeLiteralsSkipExcludedPrefixes() {
        let sources = [
            "Extraction/Table.swift": #"let abbreviation = "mr""#,
            "App/UITestHooks.swift": #"let flag = "-uitest-mute""#,
            "Reader/Page.swift": "\n" + #"let title = "Contents""#,
        ]
        XCTAssertEqual(SwiftLiterals.literals(in: sources, excluding: ["Extraction/", "App/UITest"]),
                       [SwiftLiteral(path: "Reader/Page.swift", line: 2, text: "Contents")])
    }

    // MARK: - Copy

    func testIsCopyRejectsIdentifiersURLsAndLaunchArguments() {
        for identifier in ["import.cancel", "gobackward.15", "aloud.prefs.v1.rate", "chapters.row.{expr}",
                           "https://huggingface.co/k2-fsa", "-uitest-mute", "-UIPreferredContentSizeCategoryName",
                           "", " · ", "{expr}", "{expr}%", "15"] {
            XCTAssertFalse(SwiftLiterals.isCopy(identifier), identifier)
        }
    }

    func testIsCopyAcceptsWords() {
        for copy in ["Add a file", "Import", "Back 5 min", "{expr} left", "e.g.", "Pages {expr}\\u{2013}{expr}"] {
            XCTAssertTrue(SwiftLiterals.isCopy(copy), copy)
        }
    }

    // MARK: - Code

    func testCodeDropsCommentsAndBlanksLiteralText() {
        let source = #"""
        // PrivacyCopy.line, mentioned in a comment
        let a = PrivacyCopy.line /* progressPercent */
        let b = "progressPercent is \(count)"
        """#
        let code = SwiftLiterals.code(in: source)
        XCTAssertEqual(code.components(separatedBy: "PrivacyCopy.line").count - 1, 1,
                       "Only the use in code counts, not the comment")
        XCTAssertFalse(code.contains("progressPercent"), "Comments and literal text are gone")
        XCTAssertTrue(code.contains(#"let b = "\(count)""#), "Interpolated code is still code")
        XCTAssertEqual(code.components(separatedBy: "\n").count, 3, "Lines stay put")
    }
}
