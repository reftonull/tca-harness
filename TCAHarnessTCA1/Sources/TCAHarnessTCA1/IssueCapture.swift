import Foundation
import IssueReporting
import TCAHarness

/// Records reported issues (`reportIssue`, TCA runtime warnings, `unimplemented` dependencies) in a
/// ``HarnessIssueLog``. It is added alongside the existing reporters, so Xcode still shows them.
///
/// A ``StoreHarness`` installs one for its lifetime in builds compiled with `DEBUG`. When several
/// reporters share a log, only the first in `IssueReporters.current` records, so issues are not duplicated.
public final class HarnessIssueReporter: IssueReporter {
  public let log: HarnessIssueLog

  public init(log: HarnessIssueLog = .shared) { self.log = log }

  public func reportIssue(_ message: @autoclosure () -> String?, severity: IssueSeverity,
    fileID: StaticString, filePath: StaticString, line: UInt, column: UInt) {
    let first = IssueReporters.current.lazy.compactMap { $0 as? HarnessIssueReporter }.first { $0.log === self.log }
    guard first === self else { return }
    let text = message() ?? ""
    log.record(kind: "issue", message: text.isEmpty ? "Issue reported" : text, file: "\(fileID)", line: Int(line))
  }

  /// Appends a reporter for `log` to `IssueReporters.current` and returns it.
  public static func install(log: HarnessIssueLog = .shared) -> HarnessIssueReporter {
    let reporter = HarnessIssueReporter(log: log)
    IssueReporters.current.append(reporter)
    return reporter
  }

  /// Removes this reporter from `IssueReporters.current`.
  public func uninstall() {
    IssueReporters.current.removeAll { ($0 as? HarnessIssueReporter) === self }
  }
}
