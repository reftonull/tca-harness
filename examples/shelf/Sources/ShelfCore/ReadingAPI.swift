import Foundation

/// `GET /stats`: totals and books per author.
public struct ReadingStats: Codable, Equatable, Sendable {
  public struct AuthorCount: Codable, Equatable, Sendable {
    public var author: String
    public var count: Int
  }
  public var total: Int
  public var read: Int
  public var unread: Int
  public var byAuthor: [AuthorCount]
}

/// `GET /goal` and `PUT /goal`: the yearly goal, and how many books are read so far.
public struct ReadingGoal: Codable, Equatable, Sendable {
  public var yearly: Int
  public var read: Int
}

/// The endpoints behind the two vanilla SwiftUI screens (Reading stats, Reading goal). A plain
/// struct of closures passed to the models' initializers, the way a team without TCA injects a client.
/// It shares `HTTP.live`, and so the harness-routed URLSession, with the TCA features.
public struct ReadingAPI: Sendable {
  public var fetchStats: @Sendable () async throws -> ReadingStats
  public var fetchGoal: @Sendable () async throws -> ReadingGoal
  public var saveGoal: @Sendable (_ yearly: Int) async throws -> ReadingGoal

  public init(fetchStats: @escaping @Sendable () async throws -> ReadingStats,
    fetchGoal: @escaping @Sendable () async throws -> ReadingGoal,
    saveGoal: @escaping @Sendable (_ yearly: Int) async throws -> ReadingGoal) {
    self.fetchStats = fetchStats; self.fetchGoal = fetchGoal; self.saveGoal = saveGoal
  }

  public static var live: ReadingAPI {
    let http = HTTP.live
    struct GoalUpdate: Encodable { var yearly: Int }
    return ReadingAPI(
      fetchStats: { try await http.send("GET", "/stats", decode: ReadingStats.self) },
      fetchGoal: { try await http.send("GET", "/goal", decode: ReadingGoal.self) },
      saveGoal: { try await http.send("PUT", "/goal", body: GoalUpdate(yearly: $0), decode: ReadingGoal.self) }
    )
  }
}
