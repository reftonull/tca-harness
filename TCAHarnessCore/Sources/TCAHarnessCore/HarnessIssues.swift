import Foundation

/// One entry in a ``HarnessIssueLog``: a runtime issue, a violated invariant, or a network problem.
public struct HarnessIssue: Codable, Sendable, Equatable {
  /// Increases by one per recorded issue, starting at 1. Pass the last seen value as `since`.
  public let seq: Int
  /// `issue` (a reported runtime issue), `invariant` (a descriptor invariant became false) or
  /// `network` (a request had no fixture, or was blocked).
  public let kind: String
  public let message: String
  /// File name of the report site, when known.
  public let file: String?
  public let line: Int?
  /// Case path of the most recently reduced action, e.g. `shelf.deleteResponse`, when a timeline
  /// recorder is attached.
  public let action: String?

  public init(seq: Int, kind: String, message: String, file: String? = nil, line: Int? = nil, action: String? = nil) {
    self.seq = seq; self.kind = kind; self.message = message; self.file = file; self.line = line; self.action = action
  }

  private enum CodingKeys: String, CodingKey { case seq, kind, message, file, line, action }

  // Absent values are encoded as `null` so every entry has the same keys on the wire.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(seq, forKey: .seq)
    try container.encode(kind, forKey: .kind)
    try container.encode(message, forKey: .message)
    try container.encode(file, forKey: .file)
    try container.encode(line, forKey: .line)
    try container.encode(action, forKey: .action)
  }
}

/// Thread-safe, bounded log of issues found while a harness is attached. Served by the session's
/// `issues` method; every observation carries its ``count`` as `issueCount`.
public final class HarnessIssueLog: @unchecked Sendable {
  /// The log used by default by sessions, attachments and ``HarnessNetwork``.
  public static let shared = HarnessIssueLog()

  /// Maximum number of retained entries; older entries are dropped, sequence numbers keep counting.
  public let capacity: Int
  private let lock = NSLock()
  private var entries: [HarnessIssue] = []
  private var sequence = 0
  private var actionProvider: (@Sendable () -> String?)?

  public init(capacity: Int = 1000) { self.capacity = max(capacity, 1) }

  /// Total number of issues recorded so far, which is also the latest `seq`.
  public var count: Int { lock.lock(); defer { lock.unlock() }; return sequence }

  /// Supplies `action` for issues recorded without one, usually the timeline's latest reduced action.
  public func setActionProvider(_ provider: (@Sendable () -> String?)?) {
    lock.lock(); actionProvider = provider; lock.unlock()
  }

  /// Records an issue and returns it. `file` may be a path or `#fileID`; only its last component is kept.
  /// Without `action`, the action provider's value is used.
  @discardableResult
  public func record(kind: String, message: String, file: String? = nil, line: Int? = nil, action: String? = nil) -> HarnessIssue {
    let name = file.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    let provider = { lock.lock(); defer { lock.unlock() }; return actionProvider }()
    let action = action ?? provider?()
    lock.lock(); defer { lock.unlock() }
    sequence += 1
    let issue = HarnessIssue(seq: sequence, kind: kind, message: message, file: name, line: line, action: action)
    entries.append(issue)
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    return issue
  }

  /// Retained issues with `seq` greater than `since`, oldest first.
  public func issues(since: Int = 0) -> [HarnessIssue] {
    lock.lock(); defer { lock.unlock() }
    return entries.filter { $0.seq > since }
  }

  /// Drops all entries. Sequence numbers keep increasing so clients' cursors stay valid.
  public func removeAll() {
    lock.lock(); entries.removeAll(); lock.unlock()
  }
}
