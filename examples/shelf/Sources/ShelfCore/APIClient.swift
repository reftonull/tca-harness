import ComposableArchitecture
import Foundation

/// The books backend (`server.py`). Base URL from `SHELF_API`, default `http://127.0.0.1:8799`.
@DependencyClient
public struct APIClient: Sendable {
  public var fetchBooks: @Sendable () async throws -> [Book]
  public var createBook: @Sendable (_ book: Book) async throws -> Book
  public var updateBook: @Sendable (_ book: Book) async throws -> Book
  public var deleteBook: @Sendable (_ id: UUID) async throws -> Void
}

/// Fire-and-forget product analytics (`POST /events`).
@DependencyClient
public struct AnalyticsClient: Sendable {
  public var track: @Sendable (_ name: String, _ properties: [String: String]) async throws -> Void
}

public struct APIError: Error, Equatable, LocalizedError {
  public var status: Int
  public var message: String
  public var errorDescription: String? { message }
}

extension APIClient: DependencyKey {
  public static var liveValue: APIClient {
    let http = HTTP.live
    return APIClient(
      fetchBooks: { try await http.send("GET", "/books", decode: [Book].self) },
      createBook: { try await http.send("POST", "/books", body: $0, decode: Book.self) },
      updateBook: { try await http.send("PUT", "/books/\($0.id.uuidString)", body: $0, decode: Book.self) },
      deleteBook: { _ = try await http.send("DELETE", "/books/\($0.uuidString)") }
    )
  }
  public static let testValue = APIClient()
}

extension AnalyticsClient: DependencyKey {
  public static var liveValue: AnalyticsClient {
    let http = HTTP.live
    return AnalyticsClient(track: { name, properties in
      struct Event: Encodable { var name: String; var properties: [String: String] }
      _ = try await http.send("POST", "/events", body: Event(name: name, properties: properties))
    })
  }
  public static let testValue = AnalyticsClient()
}

extension DependencyValues {
  public var api: APIClient {
    get { self[APIClient.self] }
    set { self[APIClient.self] = newValue }
  }
  public var analytics: AnalyticsClient {
    get { self[AnalyticsClient.self] }
    set { self[AnalyticsClient.self] = newValue }
  }
}

/// A tiny JSON-over-HTTP helper. The session comes from `ShelfHarness.makeSession()`, which routes
/// traffic through the harness (replay, record, faults) when a harness run asks for it.
struct HTTP: Sendable {
  let base: URL
  let session: URLSession

  static let live = HTTP(
    base: URL(string: ProcessInfo.processInfo.environment["SHELF_API"] ?? "http://127.0.0.1:8799")!,
    session: ShelfHarness.makeSession()
  )

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = .sortedKeys
    return encoder
  }()
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }()

  @discardableResult
  func send(_ method: String, _ path: String, body: (some Encodable)? = Optional<Int>.none) async throws -> Data {
    var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
    request.httpMethod = method
    request.timeoutInterval = 10
    if let body {
      request.httpBody = try Self.encoder.encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message = (try? Self.decoder.decode(Problem.self, from: data))?.error ?? "The server returned \(status)."
      throw APIError(status: status, message: message)
    }
    return data
  }

  func send<Response: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Optional<Int>.none,
    decode: Response.Type) async throws -> Response {
    let data = try await send(method, path, body: body)
    do {
      return try Self.decoder.decode(Response.self, from: data)
    } catch let error as DecodingError {
      // Well-formed JSON of the wrong shape means the backend contract changed: report it as an
      // issue, not just a failed request. Invalid JSON (a truncated body) is an ordinary failure.
      if case .dataCorrupted = error {} else {
        reportIssue("\(method) \(path) returned an unexpected shape: \(Self.describe(error))")
      }
      throw APIError(status: 0, message: "The server sent something this version of Shelf can't read.")
    }
  }

  private struct Problem: Decodable { var error: String }

  static func describe(_ error: DecodingError) -> String {
    switch error {
    case let .keyNotFound(key, context):
      return "missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    case let .typeMismatch(type, context), let .valueNotFound(type, context):
      return "expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    case let .dataCorrupted(context):
      return context.debugDescription
    @unknown default:
      return "\(error)"
    }
  }
}
