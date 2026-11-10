import Foundation

/// One reduced action, as recorded by a development timeline.
public struct HarnessTimelineEntry: Codable, Sendable {
  public let index: Int
  /// Increases when the entry is recorded and again when its effect ends.
  public var sequence: Int
  /// Milliseconds since the timeline started.
  public let timeMs: Double
  public let reduceMs: Double
  /// Time the recorder added inside the reducer call.
  public let recordMs: Double
  /// Time spent snapshotting, diffing and mounting this entry when it was first served.
  public var snapshotMs: Double
  /// Enum case path, e.g. `["game", "tap"]`. Identified elements carry their id.
  public let action: [String]
  /// Projected timelines keep the payload's shape and replace values with their type.
  public let payload: HarnessJSON
  /// `app`, `effect`, or `agent`.
  public let source: String
  /// Index of the entry whose effect sent this action, when known.
  public let cause: Int?
  public let candidateID: String?
  public let state: HarnessJSON
  /// The snapshot hit its depth or size budget; changes inside cut-off parts are not visible.
  public let truncated: Bool
  /// Dotted paths that differ from the previous recorded state.
  public let changes: [String]
  public var effect: HarnessTimelineEffect?
  /// Features and operations mounted after this action; nil without a descriptor.
  public let mounts: [HarnessTimelineMount]?

  public init(index: Int, sequence: Int, timeMs: Double, reduceMs: Double, recordMs: Double, snapshotMs: Double, action: [String],
    payload: HarnessJSON, source: String, cause: Int?, candidateID: String?, state: HarnessJSON, truncated: Bool,
    changes: [String], effect: HarnessTimelineEffect?, mounts: [HarnessTimelineMount]?) {
    self.index = index; self.sequence = sequence; self.timeMs = timeMs; self.reduceMs = reduceMs
    self.recordMs = recordMs; self.snapshotMs = snapshotMs; self.action = action; self.payload = payload; self.source = source
    self.cause = cause; self.candidateID = candidateID; self.state = state; self.truncated = truncated
    self.changes = changes; self.effect = effect; self.mounts = mounts
  }

  public func withSnapshotMs(_ value: Double) -> Self {
    var copy = self; copy.snapshotMs = value; return copy
  }
}

public struct HarnessTimelineEffect: Codable, Sendable {
  /// `running`, `ended`, or `cancelled`.
  public var status: String
  public var endedMs: Double?
  public init(status: String, endedMs: Double? = nil) { self.status = status; self.endedMs = endedMs }
}

public struct HarnessTimelineMount: Codable, Sendable, Equatable {
  public let path: String
  public let name: String
  public let operations: [String]
  public init(path: String, name: String, operations: [String]) {
    self.path = path; self.name = name; self.operations = operations
  }
}

/// Entries whose sequence is greater than the requested cursor, oldest first.
public struct HarnessTimelinePage: Codable, Sendable {
  public let timelineID: String
  public let startedAt: String
  public let capacity: Int
  /// `projected` (descriptor observation, shape-only payloads) or `reflected` (all state, values).
  public let detail: String
  /// Entries evicted from the ring buffer so far.
  public let dropped: Int
  /// Pass back as `since` to continue.
  public let sequence: Int
  public let hasMore: Bool
  public let entries: [HarnessTimelineEntry]

  public init(timelineID: String, startedAt: String, capacity: Int, detail: String, dropped: Int, sequence: Int,
    hasMore: Bool, entries: [HarnessTimelineEntry]) {
    self.timelineID = timelineID; self.startedAt = startedAt; self.capacity = capacity; self.detail = detail
    self.dropped = dropped; self.sequence = sequence; self.hasMore = hasMore; self.entries = entries
  }
}
