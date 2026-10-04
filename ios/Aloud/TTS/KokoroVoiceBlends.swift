import CryptoKit
import Foundation
import OSLog

/// One of Aloud's own natural voices: a weighted mix of stock Kokoro speaker
/// tables. A Kokoro voice is a 510 × 256 table of style vectors, one row per
/// phoneme count; the first 128 columns steer the decoder (timbre), the last
/// 128 the predictor (duration, pitch, energy). A blend mixes each half on
/// its own weights.
struct KokoroVoiceBlend: Equatable {

    struct Part: Equatable {
        let speaker: String
        let weight: Float
    }

    /// "aloud_velvet" → voice id "kokoro:aloud_velvet". The `aloud_` prefix
    /// can't collide with Kokoro's `<lang><gender>_name` speakers.
    let speaker: String
    let name: String
    let subtitle: String
    /// Its table's slot in the derived voices file: a non-English speaker
    /// the app never shows.
    let slot: Int
    /// Spoken with while the derived file isn't loaded.
    let fallbackSpeaker: String
    /// Columns 0..<128, the decoder's timbre half.
    let timbre: [Part]
    /// Columns 128..<256, the predictor's prosody half.
    let prosody: [Part]

    var voiceID: String { KokoroVoiceCatalog.voiceIDPrefix + speaker }

    /// One mix for both halves.
    init(speaker: String, name: String, subtitle: String, slot: Int,
         fallbackSpeaker: String = "am_michael", mix: [Part]) {
        self.init(speaker: speaker, name: name, subtitle: subtitle, slot: slot,
                  fallbackSpeaker: fallbackSpeaker, timbre: mix, prosody: mix)
    }

    init(speaker: String, name: String, subtitle: String, slot: Int,
         fallbackSpeaker: String, timbre: [Part], prosody: [Part]) {
        self.speaker = speaker
        self.name = name
        self.subtitle = subtitle
        self.slot = slot
        self.fallbackSpeaker = fallbackSpeaker
        self.timbre = timbre
        self.prosody = prosody
    }
}

enum KokoroVoiceBlendError: Error, Equatable {
    case wrongSize
    case badRecipe
}

/// Aloud's blends, and the derived voices file that carries them: a copy of
/// the verified voices.bin with each blend's table written into its slot.
/// The pinned original is only ever read.
enum KokoroVoiceBlends {

    /// Michael lowered and smoothed: a calm, deep long-form narrator.
    static let velvet = KokoroVoiceBlend(
        speaker: "aloud_velvet", name: "Velvet", subtitle: "Low, smooth narrator", slot: 28,
        mix: [.init(speaker: "am_michael", weight: 0.6), .init(speaker: "am_onyx", weight: 0.2),
              .init(speaker: "am_adam", weight: 0.2)])

    /// Michael with Fenrir's projection: assured and even.
    static let anchor = KokoroVoiceBlend(
        speaker: "aloud_anchor", name: "Anchor", subtitle: "Polished, assured", slot: 29,
        mix: [.init(speaker: "am_michael", weight: 0.5), .init(speaker: "am_fenrir", weight: 0.3),
              .init(speaker: "am_onyx", weight: 0.2)])

    /// Michael brightened: the lightest of the three.
    static let ember = KokoroVoiceBlend(
        speaker: "aloud_ember", name: "Ember", subtitle: "Warm, upbeat", slot: 30,
        mix: [.init(speaker: "am_michael", weight: 0.7), .init(speaker: "am_fenrir", weight: 0.3)])

    /// In display order, after Michael.
    static let all: [KokoroVoiceBlend] = [velvet, anchor, ember]

    static func blend(forVoiceID id: String) -> KokoroVoiceBlend? {
        all.first { $0.voiceID == id }
    }

    // MARK: - The file's layout

    static let speakers = 53
    static let rows = 510
    static let width = 256
    static let half = 128
    static let tableFloats = rows * width
    static let expectedBytes = speakers * tableFloats * MemoryLayout<Float>.size

    /// Speakers a recipe may read: the stock English ones, which no blend
    /// slot overwrites.
    static let sourceSids = 0..<28

    static let fileName = "voices-aloud.bin"

    /// Every recipe as text, kept in the record: editing a recipe rebuilds
    /// the copy with no version to bump.
    static func recipe(for blends: [KokoroVoiceBlend] = all) -> String {
        func parts(_ parts: [KokoroVoiceBlend.Part]) -> String {
            parts.map { "\($0.speaker)*\($0.weight)" }.joined(separator: "+")
        }
        return "v1|" + blends.map { "\($0.slot):T \(parts($0.timbre))|P \(parts($0.prosody))" }
            .joined(separator: ";")
    }

    // MARK: - Mixing

    /// Writes each blend's table into its slot of `table`, a whole voices
    /// file. Every value is `acc = acc + table * weight` in Float, in recipe
    /// order from +0.0, so the result matches the reference mix bit for bit
    /// (`MacKokoroBlendSynthesisTests` pins its SHA-256).
    static func derive(into table: inout Data, blends: [KokoroVoiceBlend] = all) throws {
        guard table.count == expectedBytes else { throw KokoroVoiceBlendError.wrongSize }
        typealias Source = (offset: Int, weight: Float)
        func sources(_ parts: [KokoroVoiceBlend.Part]) throws -> [Source] {
            try parts.map { part in
                guard let sid = KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.voiceIDPrefix + part.speaker),
                      sourceSids.contains(sid) else { throw KokoroVoiceBlendError.badRecipe }
                return (sid * tableFloats, part.weight)
            }
        }
        let size = MemoryLayout<Float>.size
        for blend in blends {
            guard blend.slot >= sourceSids.upperBound, blend.slot < speakers else {
                throw KokoroVoiceBlendError.badRecipe
            }
            let timbre = try sources(blend.timbre)
            let prosody = try sources(blend.prosody)
            let base = blend.slot * tableFloats
            table.withUnsafeMutableBytes { raw in
                for row in 0..<rows {
                    for column in 0..<width {
                        let element = row * width + column
                        var acc: Float = 0
                        for source in column < half ? timbre : prosody {
                            let value = raw.loadUnaligned(fromByteOffset: (source.offset + element) * size,
                                                          as: Float.self)
                            let product = value * source.weight
                            acc = acc + product
                        }
                        raw.storeBytes(of: acc, toByteOffset: (base + element) * size, as: Float.self)
                    }
                }
            }
        }
    }

    // MARK: - The derived file

    private static let log = Logger(subsystem: "com.davidxie.Aloud", category: "kokoro")

    /// The derived voices file to load, built from `source` when missing or
    /// stale; nil to load the original instead.
    ///
    /// A current copy costs two `stat`s and a small read: the record keeps
    /// the recipe and both files' size, inode and mtime. A build reads the
    /// source once, mixes only bytes that hash to the pin, writes atomically
    /// and reads the copy back. It never creates `directory`, so a Remove
    /// can't be undone by a late load. sherpa-onnx ends the process on a
    /// voices file of the wrong length: a copy is only named at its exact
    /// size. Runs on the engine's queue.
    static func preparedVoicesFile(source: URL, in directory: URL,
                                   pinnedSHA256: String = ModelManager.voicesFile.sha256,
                                   blends: [KokoroVoiceBlend] = all,
                                   fileManager: FileManager = .default) -> URL? {
        let recipe = recipe(for: blends)
        guard let sourceStamp = ModelInstallRecord.stamp(at: source, name: source.lastPathComponent,
                                                         sha256: pinnedSHA256),
              sourceStamp.bytes == Int64(expectedBytes) else { return nil }
        let copy = directory.appendingPathComponent(fileName, isDirectory: false)

        if let record = KokoroBlendRecord.load(from: directory), record.recipe == recipe,
           record.source == sourceStamp, record.output.bytes == Int64(expectedBytes),
           ModelInstallRecord.stamp(at: copy, name: fileName, sha256: record.output.sha256) == record.output {
            return copy
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        do {
            var bytes = try Data(contentsOf: source)
            guard ModelInstallRecord.stamp(at: source, name: source.lastPathComponent,
                                           sha256: pinnedSHA256) == sourceStamp,
                  hex(SHA256.hash(data: bytes)) == pinnedSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try derive(into: &bytes, blends: blends)
            let digest = hex(SHA256.hash(data: bytes))
            try bytes.write(to: copy, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = copy
            try? excluded.setResourceValues(values)
            // A full disk can leave a short file: read it back once.
            guard try ModelManager.sha256Hex(of: copy) == digest,
                  let output = ModelInstallRecord.stamp(at: copy, name: fileName, sha256: digest),
                  output.bytes == Int64(expectedBytes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let record = KokoroBlendRecord(recipe: recipe, source: sourceStamp, output: output)
            try JSONEncoder().encode(record).write(to: KokoroBlendRecord.url(in: directory), options: .atomic)
            return copy
        } catch {
            removeDerivedFiles(in: directory, fileManager: fileManager)
            // The error's domain and code, never its own text.
            let failure = error as NSError
            log.error("kokoro blends not built: \(failure.domain, privacy: .public) \(failure.code)")
            return nil
        }
    }

    /// The copy and its record; the next load builds them again.
    static func removeDerivedFiles(in directory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName, isDirectory: false))
        try? fileManager.removeItem(at: KokoroBlendRecord.url(in: directory))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What the derived voices file was built from, kept beside it as
/// `voices-aloud.json` and written last.
struct KokoroBlendRecord: Codable, Equatable {

    static let fileName = "voices-aloud.json"

    let recipe: String
    /// voices.bin as it was read: its pinned hash, size, inode and mtime.
    let source: ModelInstallRecord.File
    /// voices-aloud.bin as written: the hash of its bytes, size, inode and mtime.
    let output: ModelInstallRecord.File

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(from directory: URL) -> KokoroBlendRecord? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(KokoroBlendRecord.self, from: data)
    }
}
