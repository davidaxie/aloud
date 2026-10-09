import XCTest
@testable import Aloud

/// The one voice and speed formatter (ListeningFormat) and the speed scale
/// (SpeedScale) every speed control shares.
final class ListeningFormatTests: XCTestCase {

    // MARK: - SpeedScale

    func testPresetsAreThePRDSet() {
        XCTAssertEqual(SpeedScale.presets, [1, 1.25, 1.5, 2, 2.5])
        XCTAssertEqual(SpeedScale.range, 0.5...3.0)
        XCTAssertEqual(SpeedScale.step, 0.05)
    }

    func testSnapTable() {
        let table: [(raw: Double, snapped: Double)] = [
            (0.96, 1), (1.04, 1),          // inside the ±0.04 detent, inclusive
            (1.041, 1.05), (0.959, 0.95),  // just outside it
            (1.37, 1.35),                  // nearest 0.05 step
            (0.3, 0.5), (3.4, 3.0),        // clamped to the range
        ]
        for row in table {
            XCTAssertEqual(SpeedScale.snap(row.raw), row.snapped, accuracy: 1e-9, "snap(\(row.raw))")
        }
    }

    func testEverySnapIsAStepInRange() {
        for raw in stride(from: 0.0, through: 3.6, by: 0.007) {
            let snapped = SpeedScale.snap(raw)
            XCTAssertTrue(SpeedScale.range.contains(snapped), "snap(\(raw)) = \(snapped)")
            XCTAssertEqual(snapped * 20, (snapped * 20).rounded(), accuracy: 1e-9, "snap(\(raw)) = \(snapped)")
        }
    }

    func testClampedRateUsesTheScaleRange() {
        XCTAssertEqual(PlaybackController.clampedRate(0), SpeedScale.range.lowerBound)
        XCTAssertEqual(PlaybackController.clampedRate(9), SpeedScale.range.upperBound)
        XCTAssertEqual(PlaybackController.clampedRate(1.25), 1.25)
    }

    func testIsSelected() {
        XCTAssertTrue(SpeedScale.isSelected(1.5, at: 1.5000001))
        XCTAssertFalse(SpeedScale.isSelected(1.5, at: 1.55))
    }

    /// R20: the detent ticks only on arriving at 1×.
    func testLandsOnDetentTable() {
        let table: [(from: Double, to: Double, lands: Bool)] = [
            (0.95, 1, true),      // arriving
            (1, 1.05, false),     // leaving
            (1, 1, false),        // holding
            (0.9, 0.95, false),   // nowhere near
        ]
        for row in table {
            XCTAssertEqual(SpeedScale.landsOnDetent(from: row.from, to: row.to), row.lands,
                           "landsOnDetent(from: \(row.from), to: \(row.to))")
        }
    }

    // MARK: - ListeningFormat

    func testWholeRate() {
        XCTAssertEqual(ListeningFormat.rate(1), "1×")
        XCTAssertEqual(ListeningFormat.rate(2), "2×")
    }

    func testFractionalRates() throws {
        // `formatted()` follows the device locale; these strings assume en_US.
        try XCTSkipUnless(Locale.current.decimalSeparator == ".", "needs a '.' decimal separator")
        XCTAssertEqual(ListeningFormat.rate(1.25), "1.25×")
        XCTAssertEqual(ListeningFormat.rate(2.5), "2.5×")
        XCTAssertEqual(ListeningFormat.rate(1.2499999), "1.25×", "rounded to the hundredth")
        XCTAssertEqual(ListeningFormat.chipTitle(voice: michael, rate: 1.25), "Michael · 1.25×")
        #if os(iOS)
        // H058: Settings' row says the chip's value without its middle dot,
        // which VoiceOver reads aloud as a word, after the visible title;
        // R4-23: the speed in words, as the speed track says it.
        XCTAssertEqual(SettingsView.listeningRowSpokenLabel(voice: michael, rate: 1.25), "Voice & speed, Michael, 1.25 times")
        XCTAssertFalse(SettingsView.listeningRowSpokenLabel(voice: michael, rate: 1.25).contains("×"))
        XCTAssertFalse(SettingsView.listeningRowSpokenLabel(voice: michael, rate: 1.25).contains("\u{00B7}"))
        #endif
    }

    func testSpokenRateIsWords() throws {
        try XCTSkipUnless(Locale.current.decimalSeparator == ".", "needs a '.' decimal separator")
        XCTAssertEqual(ListeningCopy.spokenRate(1), "1 times speed")
        XCTAssertEqual(ListeningCopy.spokenRate(1.25), "1.25 times speed")
        XCTAssertEqual(ListeningCopy.spokenRate(2.5), "2.5 times speed")
        XCTAssertFalse(SpeedScale.presets.map(ListeningCopy.spokenRate).contains { $0.contains("×") })
    }

    /// R4-23: the speed track and the Settings row say a speed in words,
    /// the presets' words without their "speed", which the track's label
    /// already says; the presets keep theirs unchanged.
    func testSpokenTimesIsTheRateInWords() throws {
        try XCTSkipUnless(Locale.current.decimalSeparator == ".", "needs a '.' decimal separator")
        XCTAssertEqual(ListeningCopy.spokenTimes(1.25), "1.25 times")
        XCTAssertEqual(ListeningCopy.spokenTimes(1), "1 times")
        XCTAssertEqual(ListeningCopy.spokenTimes(0.85), "0.85 times")
        XCTAssertEqual(ListeningCopy.spokenRate(1.25), "1.25 times speed", "the presets' words are unchanged")
        for rate in stride(from: 0.5, through: 3.0, by: 0.05) {
            XCTAssertFalse(ListeningCopy.spokenTimes(rate).contains("×"), "\(rate)")
            XCTAssertEqual(ListeningCopy.spokenRate(rate), ListeningCopy.spokenTimes(rate) + " speed")
        }
    }

    func testIdentifierNumberIsLocaleFree() {
        XCTAssertEqual(ListeningFormat.identifierNumber(1), "1")
        XCTAssertEqual(ListeningFormat.identifierNumber(1.25), "1.25")
        XCTAssertEqual(ListeningFormat.identifierNumber(2.5), "2.5")
    }

    func testShortName() {
        XCTAssertEqual(ListeningFormat.shortName(AVSpeechEngine(mutesOutput: true).defaultVoice), "System")
        XCTAssertEqual(ListeningFormat.shortName(michael), "Michael")
    }

    // MARK: - Stand-in notes (F073, F095)

    /// A blend whose voices file couldn't load stays in the list and says it
    /// speaks as Michael; loaded, or before any load decides, it says
    /// nothing more. A stock voice always speaks as itself.
    func testABlendThatCannotLoadSaysItSpeaksAsItsFallback() throws {
        XCTAssertEqual(KokoroVoiceBlends.all.count, 3)
        for blend in KokoroVoiceBlends.all {
            let voice = try XCTUnwrap(KokoroVoiceCatalog.curatedVoices.first { $0.id == blend.voiceID })
            XCTAssertEqual(ListeningView.standInNote(for: voice, blendsAvailable: false, standingInFor: nil),
                           "speaking as Michael for now", blend.name)
            XCTAssertNil(ListeningView.standInNote(for: voice, blendsAvailable: true, standingInFor: nil))
            XCTAssertNil(ListeningView.standInNote(for: voice, blendsAvailable: nil, standingInFor: nil))
        }
        XCTAssertNil(ListeningView.standInNote(for: KokoroVoiceCatalog.defaultVoice, blendsAvailable: false,
                                               standingInFor: nil))

        let velvet = try XCTUnwrap(KokoroVoiceCatalog.curatedVoices.first {
            $0.id == KokoroVoiceBlends.all[0].voiceID
        })
        let subtitle = ListeningCopy.subtitle(velvet.subtitle, note: ListeningCopy.blendStandIn(speaker: "Michael"))
        XCTAssertEqual(subtitle, velvet.subtitle + " \u{00B7} speaking as Michael for now")
        XCTAssertEqual(ListeningView.accessibilityLabel(name: velvet.name, subtitle: subtitle,
                                                        origin: "US \u{00B7} male", spokenOrigin: "American, male"),
                       "\(velvet.name), \(velvet.subtitle), speaking as Michael for now, American, male",
                       "VoiceOver hears commas, never the middle dot, and an accent, never letters")
        XCTAssertEqual(ListeningCopy.subtitle(velvet.subtitle, note: nil), velvet.subtitle)
    }

    /// The System voice in use while a natural voice is the stored pick (the
    /// device cooling, or the natural voice failed) says it stands in, so
    /// picking it again, which changes nothing, is explained. Picked for
    /// itself, it says nothing more.
    func testTheSystemVoiceStandingInForANaturalVoiceSaysSo() {
        let system = TtsVoice(id: AVSpeechEngine.systemVoiceID, name: "System voice", lang: "en-US",
                              gender: "", engine: .avSpeech, quality: 1)
        let natural = KokoroVoiceCatalog.defaultVoice
        XCTAssertEqual(ListeningView.standInNote(for: system, blendsAvailable: nil, standingInFor: natural),
                       "standing in for Michael")
        XCTAssertEqual(ListeningCopy.subtitle("Built-in fallback",
                                              note: ListeningView.standInNote(for: system, blendsAvailable: true,
                                                                              standingInFor: natural)),
                       "Built-in fallback \u{00B7} standing in for Michael")
        XCTAssertNil(ListeningView.standInNote(for: system, blendsAvailable: nil, standingInFor: system))
        XCTAssertNil(ListeningView.standInNote(for: system, blendsAvailable: false, standingInFor: nil))
        XCTAssertNil(ListeningView.standInNote(for: natural, blendsAvailable: nil, standingInFor: natural),
                     "a natural voice is never a stand-in")
    }

    // MARK: - The origin in words (R4-26)

    /// The row draws "US · male"; VoiceOver says the accent and the gender,
    /// and nothing for the System voice.
    @MainActor
    func testTheOriginIsSpokenAsAnAccent() throws {
        let emma = try XCTUnwrap(KokoroVoiceCatalog.curatedVoices.first { $0.name == "Emma" })
        XCTAssertEqual(ListeningView.origin(for: emma), "GB \u{00B7} female", "the drawn origin stays")
        XCTAssertEqual(ListeningView.spokenOrigin(for: emma), "British, female")
        XCTAssertEqual(ListeningView.spokenOrigin(for: KokoroVoiceCatalog.defaultVoice), "American, male")
        XCTAssertEqual(ListeningView.accessibilityLabel(name: emma.name, subtitle: emma.subtitle,
                                                        origin: ListeningView.origin(for: emma),
                                                        spokenOrigin: ListeningView.spokenOrigin(for: emma)),
                       "Emma, Gentle, mellow, British, female")
        let system = TtsVoice(id: AVSpeechEngine.systemVoiceID, name: "System voice", lang: "en-US",
                              gender: "", engine: .avSpeech, quality: 1)
        XCTAssertEqual(ListeningView.spokenOrigin(for: system), "", "the System voice has no origin")
        XCTAssertEqual(ListeningCopy.accent(forRegion: "AU"), "Australia", "another region: its English name")
    }

    /// A voice with no description of its own shows its origin as its
    /// subtitle: VoiceOver says the accent there, once, never the letters,
    /// with or without a stand-in note after it.
    @MainActor
    func testARowWhoseSubtitleIsItsOriginNeverSpeaksTheLetters() {
        for (lang, accent) in [("en-US", "American"), ("en-GB", "British")] {
            let voice = TtsVoice(id: "kokoro:test_\(lang)", name: "Test", lang: lang, gender: "female",
                                 engine: .kokoro, quality: 4)
            let origin = ListeningView.origin(for: voice)
            let spoken = ListeningView.spokenOrigin(for: voice)
            let bare = ListeningView.accessibilityLabel(name: voice.name, subtitle: origin, origin: origin,
                                                        spokenOrigin: spoken)
            XCTAssertEqual(bare, "Test, \(accent), female")
            let noted = ListeningView.accessibilityLabel(
                name: voice.name, subtitle: ListeningCopy.subtitle(origin, note: ListeningCopy.blendStandIn(speaker: "Michael")),
                origin: origin, spokenOrigin: spoken)
            XCTAssertEqual(noted, "Test, \(accent), female, speaking as Michael for now")
            for label in [bare, noted] {
                for letters in ["US", "GB"] {
                    XCTAssertFalse(label.components(separatedBy: ", ").contains(letters), label)
                }
            }
        }
    }

    /// No curated voice's row says its region as letters.
    @MainActor
    func testNoCuratedVoiceSpeaksItsRegionAsLetters() {
        XCTAssertEqual(KokoroVoiceCatalog.curatedVoices.count, 11)
        for voice in KokoroVoiceCatalog.curatedVoices {
            let label = ListeningView.accessibilityLabel(name: voice.name, subtitle: voice.subtitle,
                                                         origin: ListeningView.origin(for: voice),
                                                         spokenOrigin: ListeningView.spokenOrigin(for: voice))
            XCTAssertFalse(label.contains(", US,") || label.hasSuffix(", US"), label)
            XCTAssertFalse(label.contains(", GB"), label)
            XCTAssertFalse(label.contains("\u{00B7}"), label)
            XCTAssertTrue(label.hasSuffix(", American, male") || label.hasSuffix(", American, female")
                          || label.hasSuffix(", British, female"), label)
        }
    }

    private let michael = TtsVoice(id: "kokoro:am_michael", name: "Michael", lang: "en-US",
                                   gender: "m", engine: .kokoro, quality: 2)
}
