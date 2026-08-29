import Foundation

enum AgentMarkdownTableAlignment: Equatable, Sendable {
  case leading
  case center
  case trailing
}

enum AgentMarkdownBlockContent: Equatable, Sendable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case unorderedList([String])
  case orderedList([String])
  case quote(String)
  case code(language: String?, text: String)
  case table(
    headers: [String],
    rows: [[String]],
    alignments: [AgentMarkdownTableAlignment]
  )
  case thematicBreak
}

struct AgentMarkdownBlock: Identifiable, Equatable, Sendable {
  let id: String
  let content: AgentMarkdownBlockContent
}

struct AgentMarkdownDocument: Equatable, Sendable {
  let blocks: [AgentMarkdownBlock]
  private let source: String

  init(_ content: String) {
    source = content
    blocks = AgentMarkdownDocumentParser.parse(content)
  }

  func updating(content: String) -> Self {
    guard content != source else { return self }
    let parsedBlocks = AgentMarkdownDocumentParser.parse(content)
    let blocks = parsedBlocks.enumerated().map { index, block in
      guard index < self.blocks.count, self.blocks[index].content == block.content else {
        return block
      }
      return self.blocks[index]
    }
    return Self(source: content, blocks: blocks)
  }

  private init(source: String, blocks: [AgentMarkdownBlock]) {
    self.source = source
    self.blocks = blocks
  }
}
