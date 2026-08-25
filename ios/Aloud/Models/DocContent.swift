import Foundation

/// The extracted document — sentences are the atom of synthesis, highlight, and seek.

struct Sentence: Codable, Identifiable {
    let id: Int
    let text: String
    let para: Int
    let page: Int
}

struct Paragraph: Codable, Identifiable {
    let id: Int
    let sentenceIDs: Range<Int>
    let page: Int
}

struct DocContent: Codable {
    let title: String
    let pageCount: Int
    let sentences: [Sentence]
    let paragraphs: [Paragraph]
    let contentHash: String   // SHA256 of joined sentence text
}
