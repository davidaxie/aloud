import XCTest
@testable import Aloud

/// Gutenberg Contents lists in the layouts the bundled classics actually use:
/// the list is never read aloud, and reading starts at the book's first
/// listed section — without skipping a preface the Contents doesn't list.
final class ExtractionFrontMatterTests: XCTestCase {

    private func makeTextFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-frontmatter-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func extract(_ contents: String) async throws -> DocContent {
        try await ExtractionPipeline()
            .extractText(fileURL: makeTextFile(contents), title: "Test Book", progress: nil)
    }

    private func occurrences(of needle: String, in content: DocContent) -> Int {
        content.sentences.map(\.text).joined(separator: " ")
            .components(separatedBy: needle).count - 1
    }

    /// A hard-wrapped body paragraph of `lines` lines (prose width).
    private func prose(_ topic: String, lines: Int = 3) -> String {
        (1...lines).map { "The \(topic) went on for a while, line \($0) of it, and nobody minded it at all" }
            .joined(separator: "\n") + "."
    }

    // MARK: - One entry per paragraph (Moby-Dick)

    func testOneEntryPerParagraphContentsIsSkipped() async throws {
        let entries = (1...30).map { "CHAPTER \($0). Title Number \($0)." }.joined(separator: "\n\n")
        let content = try await extract("""
        MOBY-DICK;

        By Herman Melville

        CONTENTS

        ETYMOLOGY.

        EXTRACTS (Supplied by a Sub-Sub-Librarian).

        \(entries)

        Epilogue

        Original Transcriber’s Notes:

        \(prose("transcription note", lines: 4))

        ETYMOLOGY.

        (Supplied by a Late Consumptive Usher to a Grammar School.)

        \(prose("usher"))

        CHAPTER 1. Title Number 1.

        \(prose("first chapter"))

        CHAPTER 2. Title Number 2.

        \(prose("second chapter"))
        """)

        // Reading starts at the body copy of the first entry, not inside the list.
        XCTAssertEqual(content.sentences.first?.text, "ETYMOLOGY.")
        XCTAssertEqual(occurrences(of: "Title Number 1.", in: content), 1)
        XCTAssertEqual(occurrences(of: "Title Number 30", in: content), 0)
        XCTAssertEqual(occurrences(of: "Melville", in: content), 0)
        // A short transcriber's note between the list and the book is skipped.
        XCTAssertEqual(occurrences(of: "transcription note", in: content), 0)
        // Etymology, chapter 1 and chapter 2 — no chapter per Contents line.
        XCTAssertEqual(content.pageCount, 3)
        XCTAssertEqual(content.derivedChapters.count, 3)
    }

    func testBookHeadingRightAfterOneEntryPerParagraphContents() async throws {
        // War and Peace: the body's first heading directly follows the list
        // and is itself followed by a chapter heading, not by more entries.
        let entries = (1...12).map { "CHAPTER \(romanNumeral($0))" }.joined(separator: "\n\n")
        let content = try await extract("""
        WAR AND PEACE

        Contents

        BOOK ONE: 1805

        \(entries)

        BOOK ONE: 1805

        CHAPTER I

        \(prose("salon"))

        CHAPTER II

        \(prose("evening"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "BOOK ONE: 1805")
        XCTAssertEqual(occurrences(of: "BOOK ONE", in: content), 1)
        XCTAssertEqual(occurrences(of: "CHAPTER XII", in: content), 0)
        XCTAssertEqual(content.pageCount, 3)
    }

    // MARK: - Lists the old strict test rejected

    func testLongContentsBlockPastTheEightyLineWindowIsSkipped() async throws {
        // Great Expectations: 59 entries in one block, "Chapter I." on line 81.
        let list = (1...59).map { "Chapter \(romanNumeral($0))." }.joined(separator: "\n")
        let content = try await extract("""
        [Illustration]

        Great Expectations

        [1867 Edition]

        by Charles Dickens

        Contents

        \(list)

        Chapter I.

        \(prose("marsh"))

        Chapter II.

        \(prose("forge"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "Chapter I.")
        XCTAssertEqual(occurrences(of: "Chapter LIX", in: content), 0)
        XCTAssertEqual(occurrences(of: "Dickens", in: content), 0)
        XCTAssertEqual(content.pageCount, 2)
    }

    func testUnnumberedFirstEntryStartsReading() async throws {
        // The Picture of Dorian Gray: "THE PREFACE" fails the numeral test,
        // and the preface is part of the book.
        let chapters = (1...20).map { " CHAPTER \(romanNumeral($0))." }.joined(separator: "\n")
        let content = try await extract("""
        The Picture of Dorian Gray

        by Oscar Wilde

        Contents

         THE PREFACE
        \(chapters)

        THE PREFACE

        \(prose("artist"))

        CHAPTER I.

        \(prose("studio"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "THE PREFACE")
        XCTAssertEqual(occurrences(of: "CHAPTER XX", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("artist") })
        XCTAssertEqual(content.pageCount, 2)
    }

    func testLongEntryLinesAreStillAContentsList() async throws {
        // Around the World in Eighty Days: entries far longer than 60 characters.
        let content = try await extract("""
        Around the World in Eighty Days

        Contents

         CHAPTER I. IN WHICH PHILEAS FOGG AND PASSEPARTOUT ACCEPT EACH OTHER, THE ONE AS MASTER, THE OTHER AS MAN
         CHAPTER II. IN WHICH PASSEPARTOUT IS CONVINCED THAT HE HAS AT LAST FOUND HIS IDEAL

        CHAPTER I.
        IN WHICH PHILEAS FOGG AND PASSEPARTOUT ACCEPT EACH OTHER, THE ONE AS
        MASTER, THE OTHER AS MAN

        \(prose("club"))

        CHAPTER II.
        IN WHICH PASSEPARTOUT IS CONVINCED THAT HE HAS AT LAST FOUND HIS IDEAL

        \(prose("servant"))
        """)
        XCTAssertEqual(content.sentences.first?.text.hasPrefix("CHAPTER I."), true)
        XCTAssertEqual(occurrences(of: "PASSEPARTOUT IS CONVINCED", in: content), 1)
        XCTAssertEqual(content.pageCount, 2)
    }

    // MARK: - Nothing real is skipped

    func testUnlistedForewordIsKept() async throws {
        // The Gods of Mars: a foreword the Contents doesn't list comes before
        // Chapter I. Only the list goes; the foreword and its heading stay,
        // however short the foreword is.
        for parts in [1, 2, 6] {
            let foreword = (1...parts).map { prose("foreword part \($0)") }.joined(separator: "\n\n")
            let content = try await extract("""
            THE GODS OF MARS

            CONTENTS

             CHAPTER I. THE PLANT MEN
             CHAPTER II. A FOREST BATTLE

            FOREWORD

            \(foreword)

            CHAPTER I
            THE PLANT MEN

            \(prose("valley"))
            """)
            XCTAssertEqual(content.sentences.first?.text, "FOREWORD", "\(parts) part(s)")
            XCTAssertTrue(content.sentences.contains { $0.text.contains("foreword part 1") }, "\(parts) part(s)")
            XCTAssertEqual(occurrences(of: "FOREST BATTLE", in: content), 0)
            XCTAssertEqual(occurrences(of: "THE PLANT MEN", in: content), 1)
            XCTAssertEqual(content.pageCount, 2)
        }
    }

    func testShortPrefatoryNoteWithoutHeadingIsKept() async throws {
        // Dracula: a one-paragraph note between the Contents and Chapter I.
        let content = try await extract("""
        DRACULA

        Contents

        CHAPTER I. A Journal Begun
        CHAPTER II. A Journal Continued
        CHAPTER III. A Journal Ended

        \(prose("prefatory note", lines: 4))

        DRACULA

        CHAPTER I

        A JOURNAL BEGUN

        \(prose("journey"))

        CHAPTER II

        A JOURNAL CONTINUED

        \(prose("castle"))
        """)
        XCTAssertEqual(content.sentences.first?.text.hasPrefix("The prefatory note went on"), true)
        XCTAssertEqual(occurrences(of: "A Journal Ended", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("journey went on") })
    }

    func testShortDedicationBetweenListAndChapterIsSkipped() async throws {
        let content = try await extract("""
        A Tale

        Contents

        I. The Beginning
        II. The End

        For my wife, who listened to every word of it.

        I

        THE BEGINNING

        \(prose("opening"))

        II

        THE END

        \(prose("ending"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "I")
        XCTAssertEqual(occurrences(of: "my wife", in: content), 0)
    }

    func testVersePrologueTheContentsDoesntListIsKept() async throws {
        // The Belle of Bowling Green: an italic "_Prologue_" heading and three
        // stanzas between the Contents and Chapter One.
        let stanza = (1...8).map { "The river ran beside the town in stanza line \($0)," }.joined(separator: "\n")
        let content = try await extract("""
        The Belle

        CONTENTS

        CHAPTER PAGE

        I MONDAY'S CHILDREN 3

        II THE SPRING OF THE YEAR 30

        III AFTERWARD 61

        _Prologue_

        \(stanza)

        \(stanza)

        \(stanza)

        CHAPTER ONE

        MONDAY'S CHILDREN

        \(prose("morning"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "Prologue")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("stanza line 1") })
        XCTAssertEqual(occurrences(of: "THE SPRING OF THE YEAR", in: content), 0)
    }

    func testIllustrationListIsNotReadAsAPreface() async throws {
        // Captions written as sentences, set as a list after the Contents.
        let content = try await extract("""
        OFFICER NINE

        CONTENTS

        CHAPTER I. A MORNING PRELUDE
        CHAPTER II. THE EVENING AFTER

        ILLUSTRATIONS

          His gaze had wandered over to the old chest, the lid of
              which was slowly and quite distinctly rising.       Frontispiece
          "Now here is a clever little line of yours", he went on. "That
              shows us something else entirely, does it not?"           88

          "Give me the uniform and let me get out of this place at once."   154

        OFFICER NINE

        CHAPTER I.

        A MORNING PRELUDE.

        \(prose("breakfast"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "CHAPTER I.")
        XCTAssertEqual(occurrences(of: "old chest", in: content), 0)
        XCTAssertEqual(occurrences(of: "uniform", in: content), 0)
    }

    // MARK: - The first chapter is never swallowed

    func testChapterOneAfterARepeatedBookTitleIsKept() async throws {
        // The Rover Boys on the Farm: one entry per paragraph, the book title
        // again, then "CHAPTER I", its title and two short lines of dialogue.
        let entries = ["I. SOMETHING ABOUT THE BOYS", "II. WHAT HAPPENED ON THE HILL",
                       "III. A MYSTERIOUS CAVE", "IV. AT THE FARM"].joined(separator: "\n\n")
        let content = try await extract("""
        THE BOYS ON THE FARM

        CONTENTS.

        \(entries)

        THE BOYS ON THE FARM

        CHAPTER I

        SOMETHING ABOUT THE BOYS

        "Sam, this is wrong."

        "I know it, Tom."

        \(prose("missing path"))

        CHAPTER II

        WHAT HAPPENED ON THE HILL

        \(prose("hill"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "CHAPTER I")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("this is wrong") })
        XCTAssertTrue(content.sentences.contains { $0.text.contains("I know it, Tom.") })
        XCTAssertEqual(occurrences(of: "A MYSTERIOUS CAVE", in: content), 0)
        XCTAssertEqual(content.pageCount, 2)
    }

    func testChapterOneRightAfterTheLastEntryIsKept() async throws {
        // The Yeoman Adventurer: the list ends "EPILOGUE: …", and the body's
        // "CHAPTER I" follows it directly.
        let entries = ["I. THE GREAT JACK", "II. THE SERGEANT", "III. THE JOURNEY",
                       "EPILOGUE: THE LITTLE JACK"].joined(separator: "\n\n")
        let content = try await extract("""
        The Yeoman

        CONTENTS

        \(entries)

        CHAPTER I

        THE GREAT JACK

        \(prose("market"))

        CHAPTER II

        THE SERGEANT

        \(prose("inn"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "CHAPTER I")
        XCTAssertEqual(occurrences(of: "LITTLE JACK", in: content), 0)
        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.sentences.first { $0.text.contains("market") }?.page, 1)
    }

    func testNumberedChapterWithItsTitleInTheNextParagraphIsKept() async throws {
        // The Secret of Chimneys: "1" alone, then the title, then dialogue;
        // the entries carry italic page numbers.
        let entries = ["1 ANTHONY SIGNS ON _1_", "2 A LADY IN DISTRESS _11_",
                       "3 ANXIETY IN HIGH PLACES _20_"].joined(separator: "\n\n")
        let content = try await extract("""
        AGATHA
        WRITER

        Contents

        \(entries)

        1

        Anthony Signs On

        “Hello there, old friend!”

        \(prose("tour"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "1")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("Hello there") })
        XCTAssertEqual(occurrences(of: "DISTRESS", in: content), 0)
    }

    func testItalicRomanNumeralHeadingStartsReading() async throws {
        // Reminiscences of a Stock Operator: "_I_" is the heading "I".
        let content = try await extract("""
        REMINISCENCES

        CONTENTS

        I      1
        II     14
        III    30

        _I_

        \(prose("office"))

        _II_

        \(prose("market"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "I")
        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(occurrences(of: "14", in: content), 0)
    }

    func testPartHeadingStackedOnChapterOneIsKept() async throws {
        // The Brothers Karamazov: PART I / Book I / Chapter I open the body.
        let content = try await extract("""
        THE BROTHERS

        Contents

        PART I

        Book I. The History Of A Family

        Chapter I. The Father

        Chapter II. The First Son

        Chapter III. The Second Son

        PART I

        Book I. The History Of A Family

        Chapter I.
        The Father

        \(prose("family"))

        Chapter II.
        The First Son

        \(prose("son"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "PART I")
        XCTAssertEqual(occurrences(of: "The Second Son", in: content), 0)
        XCTAssertEqual(occurrences(of: "History Of A Family", in: content), 1)
    }

    func testRestyledPartNumberMatchesItsEntry() async throws {
        // Twenty Thousand Leagues: "PART I" in the Contents, "PART ONE" in the book.
        let content = try await extract("""
        TWENTY THOUSAND LEAGUES

        Contents

        PART I

        CHAPTER I A SHIFTING REEF

        CHAPTER II PRO AND CON

        PART ONE

        CHAPTER I
        A SHIFTING REEF

        \(prose("sea"))

        CHAPTER II
        PRO AND CON

        \(prose("debate"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "PART ONE")
        XCTAssertEqual(occurrences(of: "PRO AND CON", in: content), 1)
    }

    // MARK: - Sections printed before the Contents

    func testListedPrefaceBeforeTheContentsIsKept() async throws {
        // The Story of My Life: the Contents lists the "Editor's Preface"
        // first, but it is printed above the Contents.
        let content = try await extract("""
        THE STORY OF A LIFE

        Editor's Preface

        \(prose("preface"))

        \(prose("thanks"))

        TABLE OF CONTENTS

        Editor's Preface
        Chapter I. The Beginning
        Chapter II. The Middle

        CHAPTER I

        \(prose("childhood"))

        CHAPTER II

        \(prose("school"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "Editor's Preface")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("thanks went on") })
        XCTAssertEqual(occurrences(of: "The Middle", in: content), 0)
        XCTAssertEqual(occurrences(of: "THE STORY OF A LIFE", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("childhood went on") })
    }

    func testPrefaceBeforeTheContentsIsKept() async throws {
        // Grant's Memoirs, The Rover Boys: the author's preface sits above
        // the Contents, which doesn't list it. The title page still goes.
        let content = try await extract("""
        PERSONAL MEMOIRS

        by A. General

        PREFACE.

        \(prose("preface"))

        \(prose("acknowledgment of friends"))

        A. GENERAL.

        CONTENTS

        CHAPTER I. ANCESTRY
        CHAPTER II. WEST POINT

        CHAPTER I.

        \(prose("ancestry"))

        CHAPTER II.

        \(prose("academy"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "PREFACE.")
        XCTAssertEqual(occurrences(of: "by A. General", in: content), 0)
        XCTAssertEqual(occurrences(of: "WEST POINT", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("ancestry went on") })
    }

    // MARK: - Nothing real is dropped when no opening is found

    /// Short, unpunctuated three-line stanzas: they look like a list of titles.
    private func poems(_ count: Int, titles: (Int) -> String) -> String {
        (1...count).map { number in
            """
            \(titles(number))

            the pond in poem \(number) is silver
            a crow crosses it slowly
            cold morning light

            a second stanza for poem \(number)
            the wind is resting now
            nothing else moves
            """
        }.joined(separator: "\n\n")
    }

    func testPoetryCollectionWithDifferentBodyTitlesKeepsEveryPoem() async throws {
        let entries = (1...30).map { "\($0). Autumn Song Number \($0)      \($0 + 2)" }.joined(separator: "\n")
        let body = poems(30) { "WINTER PIECE \($0)" }
        for ending in ["", "\n\nPART II\n\nAFTERWORD\n\n" + prose("afterword", lines: 4)] {
            let content = try await extract("""
            Thirty Small Poems

            by A. Poet

            CONTENTS

            \(entries)

            \(body)\(ending)
            """)
            for number in [1, 15, 30] {
                XCTAssertEqual(occurrences(of: "the pond in poem \(number) is silver", in: content), 1,
                               "poem \(number), ending \(ending.isEmpty ? "none" : "afterword")")
            }
            XCTAssertEqual(occurrences(of: "Autumn Song Number 12", in: content), 0)
            XCTAssertNotEqual(content.sentences.first?.text, "PART II")
        }
    }

    func testPoetryCollectionWithMatchingTitlesStartsAtTheFirstPoem() async throws {
        let entries = (1...30).map { "\($0). Winter Piece \($0)      \($0 + 2)" }.joined(separator: "\n")
        let content = try await extract("""
        Thirty Small Poems

        CONTENTS

        \(entries)

        \(poems(30) { "WINTER PIECE \($0)" })
        """)
        XCTAssertEqual(content.sentences.first?.text, "WINTER PIECE 1")
        XCTAssertEqual(occurrences(of: "the pond in poem 30 is silver", in: content), 1)
    }

    func testABookOfNothingButEntriesIsKept() async throws {
        let entries = (1...2_100).map { "Chapter \($0). Some Title Words Here" }.joined(separator: "\n\n")
        let content = try await extract("A Book\n\nCONTENTS\n\n" + entries)
        XCTAssertGreaterThanOrEqual(content.paragraphs.count, 2_100)
    }

    func testOneHugeParagraphAfterTheContentsIsKept() async throws {
        let giant = (1...3_000).map { "the whole book was set as one paragraph, line \($0) of it" }
            .joined(separator: "\n")
        let content = try await extract("A Book\n\nCONTENTS\n\n" + giant)
        XCTAssertEqual(occurrences(of: "line 2999 of it", in: content), 1)
    }

    func testContentsWithNoMatchingBodyHeadingDropsOnlyTheList() async throws {
        let content = try await extract("""
        A Book of Stories

        Contents

        The First Story
        The Second Story
        The Third Story

        \(prose("story"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "A Book of Stories")
        XCTAssertEqual(occurrences(of: "Second Story", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("story went on") })
    }

    // MARK: - Capitalised verse after a list of titles

    /// Four sentence-case lines with no end punctuation: each passes for a
    /// list of titles, so the Contents walk runs on through them.
    private func stanza(_ poem: Int, _ part: Int = 1) -> String {
        """
        The lamp in song \(poem) part \(part) is burning low
        Nobody walks the road tonight
        Under the hill the river turns
        Morning is a long way off
        """
    }

    func testSongSheetAfterAListOfTitlesIsKept() async throws {
        // The list runs to the end of the file. With matching headings the
        // first song opens the book; without, the stanzas still are not a list.
        for (first, second) in [("MORNING SONG", "EVENING SONG"), ("MORNING", "EVENING")] {
            let content = try await extract("""
            CONTENTS

            Morning Song
            Evening Song

            \(first)

            \(stanza(1))

            \(stanza(1, 2))

            \(second)

            \(stanza(2))

            \(stanza(2, 2))
            """)
            for poem in [1, 2] {
                XCTAssertEqual(occurrences(of: "song \(poem) part 1 is burning", in: content), 1, first)
                XCTAssertEqual(occurrences(of: "song \(poem) part 2 is burning", in: content), 1, first)
            }
            XCTAssertEqual(content.sentences.first?.text, first)
            XCTAssertEqual(occurrences(of: "Evening Song", in: content), 0, first)
        }
    }

    func testNumberedPoemsAfterAListOfTitlesAreKept() async throws {
        // The Contents lists titles; the poems are headed I., II., … and the
        // first six are unpunctuated. Every poem and its heading is read.
        let titles = (1...12).map { "Garden Window Number \($0)" }.joined(separator: "\n")
        let poems = (1...12).map { poem -> String in
            let stanzas = poem <= 6
                ? [stanza(poem), stanza(poem, 2)]
                : ["The lamp in song \(poem) part 1 is burning low,\nand nobody walks the road tonight,\nwhile under the hill the river turns."]
            return "\(romanNumeral(poem)).\n\n" + stanzas.joined(separator: "\n\n")
        }.joined(separator: "\n\n\n")
        let content = try await extract("""
        Collected Verses

        CONTENTS

        \(titles)


        \(poems)
        """)
        for poem in 1...12 {
            XCTAssertEqual(occurrences(of: "song \(poem) part 1 is burning", in: content), 1, "poem \(poem)")
        }
        XCTAssertEqual(occurrences(of: "Garden Window Number 3", in: content), 0)
        // The title line, then one page per poem.
        XCTAssertEqual(content.pageCount, 13)
        XCTAssertEqual(content.sentences.first { $0.page == 2 }?.text, "I.")
    }

    func testPagedListOfTitlesBeforeTitleCaseStanzasKeepsEveryPoem() async throws {
        // Body titles differ from the Contents; the stanzas are in title case,
        // but they carry none of the entries' page numbers.
        let entries = (1...6).map { "Autumn Song Number \($0)      \($0 * 2 + 1)" }.joined(separator: "\n")
        let poems = (1...6).map { poem in
            "WINTER PIECE \(poem)\n\nOver The Hill In Song \(poem) The Lantern Burns\nNobody Calls And Nobody Turns\n"
                + "Grey Are The Roofs Of The Town\nBread On The Table Tonight"
        }.joined(separator: "\n\n\n")
        let content = try await extract("""
        Small Poems

        CONTENTS

        \(entries)


        \(poems)
        """)
        for poem in 1...6 {
            XCTAssertEqual(occurrences(of: "In Song \(poem) The Lantern", in: content), 1, "poem \(poem)")
        }
        XCTAssertEqual(occurrences(of: "Autumn Song Number 4", in: content), 0)
        XCTAssertTrue(content.sentences.contains { $0.text == "WINTER PIECE 1" })
    }

    func testListedTitleRecurringLaterOpensTheBody() async throws {
        // The first entry ("Dedication") is not in the body, but the second
        // recurs as the first song's heading.
        let content = try await extract("""
        Songs

        CONTENTS

        Dedication
        Morning Song
        Evening Song

        MORNING SONG

        Over The Hill The Lantern Burns
        Nobody Calls And Nobody Turns

        EVENING SONG

        Grey Are The Roofs Of The Town
        Bread On The Table Tonight
        """)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("Lantern Burns") })
        XCTAssertTrue(content.sentences.contains { $0.text.contains("Bread On The Table") })
        XCTAssertEqual(occurrences(of: "Dedication", in: content), 0)
    }

    func testChapterTitleAndDialogueAfterAListOfTitlesAreKept() async throws {
        let content = try await extract("""
        CONTENTS

        The Cold Night
        The Warm Morning
        The Long Day

        A COLD NIGHT

        "Who is there?"

        "Only me."

        "Come in, then."

        \(prose("night"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "A COLD NIGHT")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("Who is there?") })
        XCTAssertEqual(occurrences(of: "Warm Morning", in: content), 0)
    }

    // MARK: - A file that is all Contents

    func testAFileThatIsOnlyAContentsIsKept() async throws {
        // Nothing follows the list: it is the document, so it is read.
        let entries = (1...60).map { "CHAPTER \($0). The River and the Stone" }
        for (layout, text, needle) in [
            ("one block", "CONTENTS\n\n" + entries.joined(separator: "\n"), "CHAPTER 60"),
            ("one per paragraph", "CONTENTS\n\n" + entries.joined(separator: "\n\n"), "CHAPTER 60"),
            ("after a title", "Course Outline\n\nSpring Term\n\nCONTENTS\n\n" + entries.joined(separator: "\n"), "CHAPTER 60"),
            ("three entries", "CONTENTS\n\nI. The Start\nII. The Middle\nIII. The End", "The Middle"),
            ("heading only", "CONTENTS", "CONTENTS"),
        ] {
            let content = try await extract(text)
            XCTAssertTrue(content.sentences.contains { $0.text.contains(needle) }, layout)
        }
    }

    // MARK: - Prefaces

    func testPrefaceMentioningCopyrightOrProductionIsKept() async throws {
        // Words like "copyright", "produced by" and "scanning" in a preface's
        // prose do not make it a production note.
        for opening in ["When I began this translation the copyright question was still open, and the publishers waited.",
                        "This comedy was first produced by Mr. Daly at his theatre in the spring of that year, to some applause.",
                        "Readers scanning these lines for the old metre will find it changed in places, and I ask their pardon."] {
            let preface = opening + "\n" + prose("preface", lines: 3)
            let more = (1...8).map { prose("preface part \($0)") }.joined(separator: "\n\n")
            let content = try await extract("""
            A WINTER BOOK

            CONTENTS

            I. The Snow
            II. The Thaw

            PREFACE

            \(preface)

            \(more)

            CHAPTER I. THE SNOW

            \(prose("snow"))

            CHAPTER II. THE THAW

            \(prose("thaw"))
            """)
            XCTAssertEqual(content.sentences.first?.text, "PREFACE", opening)
            XCTAssertTrue(content.sentences.contains { $0.text.contains("preface part 8") }, opening)
        }
    }

    func testEditionNoticesAreStillProductionMatter() {
        XCTAssertTrue(TextExtractor.isProductionMatter("Copyright, 1907, by The Example Company"))
        XCTAssertTrue(TextExtractor.isProductionMatter("Produced by A. Volunteer and the Online Distributed Proofreading Team"))
        XCTAssertTrue(TextExtractor.isProductionMatter("Typographical errors have been corrected."))
        XCTAssertTrue(TextExtractor.isProductionMatter("[Illustration: The harbour at dawn]"))
        XCTAssertFalse(TextExtractor.isProductionMatter(prose("copyright question", lines: 4)))
        XCTAssertFalse(TextExtractor.isProductionMatter(
            "No one who scanned the crowd that morning could have guessed what was coming,\n" + prose("crowd", lines: 3)))
    }

    func testNarrowlySetPrefaceAboveTheContentsIsKept() async throws {
        // A Christmas Carol: a short preface with lines under 50 characters.
        let content = try await extract("""
        A WINTER CAROL

        by A. Writer

        PREFACE

        I HAVE tried in this small winter book to
        set down a story that will not spoil the
        season for anyone who reads it, nor make
        them cross with their neighbours or with me.
        May it sit by their fires a while, and
        leave without a fuss.

        Their faithful Friend,
        A. W.

        CONTENTS

        Stave I: The First Spirit
        Stave II: The Second Spirit

        STAVE I: THE FIRST SPIRIT

        \(prose("first spirit"))

        STAVE II: THE SECOND SPIRIT

        \(prose("second spirit"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "PREFACE")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("sit by their fires") })
        XCTAssertEqual(occurrences(of: "by A. Writer", in: content), 0)
        XCTAssertEqual(occurrences(of: "The Second Spirit", in: content), 0)
    }

    func testShortNoteAboveTheContentsIsKept() async throws {
        // An Old Man's Love: a note of under 40 words, and a signature.
        let content = try await extract("""
        AN OLD STORY

        by A. Writer

        NOTE.

        These pages were found among my uncle's papers after his death.
        He meant them as an introduction to the story that follows, and
        they are printed here exactly as he left them.

        A. WRITER THE YOUNGER.

        CONTENTS

        I. MRS BAGGETT
        II. MR WHITTLESTAFF

        CHAPTER I.

        \(prose("house"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "NOTE.")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("among my uncle's papers") })
        XCTAssertEqual(occurrences(of: "WHITTLESTAFF", in: content), 0)
    }

    func testVerseAddressToTheReaderAboveTheContentsIsKept() async throws {
        // Treasure Island: "TO THE HESITATING PURCHASER" and its verse are
        // read; the dedication above them is not.
        let verse = (1...8).map { "If tales of ships in verse line \($0) still please," }.joined(separator: "\n")
        let content = try await extract("""
        THE ISLAND

        To A. B., an old friend, with thanks for many quiet evenings by the fire.

        TO THE HESITATING PURCHASER

        \(verse)

        \(verse)

        CONTENTS

        CHAPTER I. The Old Sea-dog
        CHAPTER II. Black Dog

        CHAPTER I.

        \(prose("inn"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "TO THE HESITATING PURCHASER")
        XCTAssertTrue(content.sentences.contains { $0.text.contains("verse line 8") })
        XCTAssertEqual(occurrences(of: "old friend", in: content), 0)
        XCTAssertEqual(occurrences(of: "Black Dog", in: content), 0)
    }

    func testChapterNumberAboveAMatchedTitleIsKept() async throws {
        // The Car of Destiny: the Contents lists titles only; the body sets
        // the chapter number "I" above the title.
        let content = try await extract("""
        THE CAR

        CONTENTS

        The Royal Car
        The Guest
        The Road South

        I

        THE ROYAL CAR

        “Drive to the coast tonight? Nonsense,” said he.

        \(prose("drive"))

        II

        THE GUEST

        \(prose("guest"))
        """)
        XCTAssertEqual(content.sentences.first?.text, "I")
        XCTAssertEqual(content.pageCount, 2)
    }

    func testContentsHeadingVariantsAreRecognized() {
        XCTAssertTrue(TextExtractor.isContentsHeading("CONTENTS VOLUME I"))
        XCTAssertTrue(TextExtractor.isContentsHeading("Contents of Volume 2"))
        XCTAssertTrue(TextExtractor.isContentsHeading("Table of Contents:"))
        XCTAssertFalse(TextExtractor.isContentsHeading("Contents of the drawer"))
    }

    func testRelaxedContentsListDetection() {
        // More than 40 lines and over-long entries are still a list.
        let long = (1...59).map { "Chapter \($0)." }.joined(separator: "\n")
        XCTAssertTrue(TextExtractor.isContentsList(long))
        XCTAssertTrue(TextExtractor.isContentsList(
            "CHAPTER I. IN WHICH PHILEAS FOGG AND PASSEPARTOUT ACCEPT EACH OTHER, THE ONE AS MASTER"))
        // A list of unnumbered story titles.
        XCTAssertTrue(TextExtractor.isTitleList(
            "The Adventure of the Empty House\nThe Adventure of the Norwood Builder\nThe Adventure of the Dancing Men"))
        // An epigraph and prose are not lists.
        XCTAssertFalse(TextExtractor.isTitleList(
            "Then wear the gold hat, if that will move her;\nIf you can bounce high, bounce for her too,"))
        XCTAssertFalse(TextExtractor.isContentsList(
            "In my younger and more vulnerable years my father gave me some advice."))
    }

    // MARK: - Localized Contents (I008)

    /// The pages of `contents` and each page's first paragraph.
    private func pages(_ contents: String) throws -> [String] {
        let blocks = try TextExtractor().extract(url: makeTextFile(contents)).blocks
        return blocks.indices.filter { $0 == 0 || blocks[$0].page != blocks[$0 - 1].page }.map { blocks[$0].text }
    }

    /// 目录, 目次 and Содержание lists are skipped like an English Contents:
    /// one entry per line or per paragraph, with or without "……12" leaders,
    /// each chapter opens one page and reading starts at the first.
    func testLocalizedContentsListIsSkipped() throws {
        let zh = "　　清晨，薄雾笼罩着整个小山村，少年背起行囊走出家门。"
        let zhBody = Array(repeating: zh, count: 12).joined(separator: "\n")
        let zhTitles = ["第一章 山村少年", "第二章 进城", "第三章 风波"]
        XCTAssertEqual(try pages("山村少年\n目录\n" + zhTitles.joined(separator: "\n") + "\n"
                                 + zhTitles.map { $0 + "\n" + zhBody }.joined(separator: "\n") + "\n"),
                       zhTitles)

        let zhParagraphs = Array(repeating: zh, count: 6).joined(separator: "\n\n")
        let leaders = ["第一章　山村少年……12", "第二章　进城……34", "第三章　风波……56"]
        let spaced = ["第一章　山村少年", "第二章　进城", "第三章　风波"]
        XCTAssertEqual(try pages("山村少年\n\n目　录\n\n" + leaders.joined(separator: "\n\n") + "\n\n"
                                 + spaced.map { $0 + "\n\n" + zhParagraphs }.joined(separator: "\n\n") + "\n"),
                       spaced)

        let ja = Array(repeating: "　　朝の霧が村を包んでいた。少年は荷物を背負って家を出た。", count: 6)
            .joined(separator: "\n\n")
        let jaTitles = ["第一章　山村の少年", "第二章　町へ", "第三章　騒動"]
        XCTAssertEqual(try pages("山村の少年\n\n目次\n\n" + jaTitles.joined(separator: "\n\n") + "\n\n"
                                 + jaTitles.map { $0 + "\n\n" + ja }.joined(separator: "\n\n") + "\n"),
                       jaTitles)

        let ru = Array(repeating: "Утром туман окутал деревню, и мальчик вышел из дома с котомкой за плечами.",
                       count: 6).joined(separator: "\n\n")
        let ruTitles = ["Глава 1. Деревня", "Глава 2. Город", "Глава 3. Буря"]
        XCTAssertEqual(try pages("Деревенский мальчик\n\nСодержание\n\n" + ruTitles.joined(separator: "\n\n")
                                 + "\n\n" + ruTitles.map { $0 + "\n\n" + ru }.joined(separator: "\n\n") + "\n"),
                       ruTitles)
    }

    func testLocalizedContentsHeadings() {
        for heading in ["目录", "目錄", "目　次", "Содержание", "ОГЛАВЛЕНИЕ", "Inhalt", "Inhaltsverzeichnis",
                        "Table des matières", "SOMMAIRE", "Índice", "Indice", "목차", "차례"] {
            XCTAssertTrue(TextExtractor.isContentsHeading(heading), heading)
        }
        for line in ["目录学", "Inhalt des Briefes", "Содержание письма было простым.", "Indice di gradimento"] {
            XCTAssertFalse(TextExtractor.isContentsHeading(line), line)
        }
    }

    // MARK: - Helpers

    private func romanNumeral(_ value: Int) -> String {
        let table: [(Int, String)] = [(50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
                                      (5, "V"), (4, "IV"), (1, "I")]
        var rest = value
        var result = ""
        for (amount, symbol) in table {
            while rest >= amount { result += symbol; rest -= amount }
        }
        return result
    }
}
