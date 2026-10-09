import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Feed

/// One published release, as described by the JSON feed a release publishes
/// as an asset named `latest.json`:
///
///   {
///     "version": "1.2.0",
///     "zip":     "Pebble-1.2.0.zip",
///     "url":     "https://github.com/<owner>/<repo>/releases/download/v1.2.0/Pebble-1.2.0.zip",
///     "sha256":  "…",
///     "page":    "https://github.com/<owner>/<repo>/releases/tag/v1.2.0"
///   }
///
/// The feed is fetched through GitHub's `/releases/latest/download/` alias,
/// which always redirects to the newest non-draft, non-prerelease release —
/// no REST API call, so no rate limit.
struct UpdateRelease: Decodable {
  let version: String
  let url: String
  let sha256: String?
  let page: String?
}

// MARK: - Service

@MainActor
final class UpdateService: ObservableObject {
  /// GitHub's alias for the newest published release's `latest.json` asset.
  /// Overridable with PEBBLE_UPDATE_FEED for testing against a local server.
  static let defaultFeed = URL(string:
    "https://github.com/tuntun0609/pebble/releases/latest/download/latest.json")!

  enum State: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(String)
    case downloading(Double)
    case installing
    case ready(String)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published var autoUpdate: Bool {
    didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
  }

  /// Called on the main actor once a new version has been installed on disk
  /// and only a relaunch is left.
  var onInstalled: ((String) -> Void)?

  private var latest: UpdateRelease?
  private var installedVersion: String?
  private var feedURL: URL {
    ProcessInfo.processInfo.environment["PEBBLE_UPDATE_FEED"]
      .flatMap(URL.init(string:)) ?? Self.defaultFeed
  }

  init() {
    autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
  }

  // MARK: Status

  /// Whether this build was produced by a release workflow. Local `./build.sh`
  /// builds (no VERSION) are marked dev and never replace themselves.
  var isDevBuild: Bool {
    (Bundle.main.object(forInfoDictionaryKey: "PebbleChannel") as? String) == "dev"
  }

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }

  var isBusy: Bool {
    switch state {
    case .checking, .downloading, .installing: return true
    default: return false
    }
  }

  // MARK: Check

  /// Looks for a newer release. A user-initiated check installs it outright;
  /// an automatic one does too when `autoUpdate` is on.
  func check(userInitiated: Bool) async {
    guard !isBusy else { return }
    guard !isDevBuild else {
      state = .failed(tr("Development builds don't use automatic updates.",
                         "开发版本不参与自动更新。"))
      return
    }
    state = .checking
    do {
      let release = try await fetchFeed()
      if release.version == installedVersion {
        state = .ready(release.version)
      } else if Self.isNewer(release.version, than: currentVersion) {
        latest = release
        if userInitiated || autoUpdate {
          await downloadAndInstall(release)
        } else {
          state = .available(release.version)
        }
      } else {
        state = .upToDate(currentVersion)
      }
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Installs the release found by the last check, if any.
  func installAvailable() async {
    guard let release = latest else { return await check(userInitiated: true) }
    await downloadAndInstall(release)
  }

  // MARK: Download → verify → stage → install

  private func downloadAndInstall(_ release: UpdateRelease) async {
    do {
      guard let url = URL(string: release.url) else { throw UpdateError.badFeed }
      state = .downloading(0)
      let zip = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pebble-\(release.version)-\(UUID().uuidString).zip")
      defer { try? FileManager.default.removeItem(at: zip) }
      try await Downloader.run(url: url, to: zip) { [weak self] progress in
        Task { @MainActor in self?.state = .downloading(progress) }
      }

      if let expected = release.sha256, !expected.isEmpty {
        let actual = try Self.sha256(of: zip)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
          throw UpdateError.checksumMismatch
        }
      }

      state = .installing
      latest = release
      let staged = try stage(zip: zip, version: release.version)
      try install(staged: staged, version: release.version)
    } catch {
      cleanUpStaging()
      state = .failed(error.localizedDescription)
    }
  }

  /// Drops anything a failed update left staged, so the next attempt starts
  /// from a clean directory.
  private func cleanUpStaging() {
    let fm = FileManager.default
    let parent = Bundle.main.bundleURL.deletingLastPathComponent()
    try? fm.removeItem(at: parent.appendingPathComponent(".pebble-update"))
    let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Pebble/update")
    try? fm.removeItem(at: cache)
  }

  /// Unpacks the downloaded zip beside the bundle (or in the cache when that
  /// directory isn't writable), then checks its signature.
  private func stage(zip: URL, version: String) throws -> URL {
    let bundle = Bundle.main.bundleURL
    if let blocker = replacementBlocker(for: bundle) {
      throw UpdateError.stuck(blocker)
    }
    return try unpack(zip: zip, into: stagingDirectory(for: bundle), version: version)
  }

  private func unpack(zip: URL, into dir: URL, version: String) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("app")
    try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
    let app = out.appendingPathComponent("\(Self.appName).app")
    guard fm.fileExists(atPath: app.path) else { throw UpdateError.unpack }
    // The payload must be the same app, and the version the feed announced.
    guard let staged = Bundle(url: app),
          staged.bundleIdentifier == Bundle.main.bundleIdentifier,
          staged.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
      throw UpdateError.unpack
    }
    // A download this app fetched carries no quarantine flag, but clear any
    // that rode along so Gatekeeper never re-prompts on the new copy.
    _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    try verifySignature(of: app)
    return app
  }

  /// Swaps the staged app in for the running bundle, putting the old one back
  /// if the second move fails. Falls back to the administrator's password when
  /// the folder isn't writable.
  private func install(staged: URL, version: String) throws {
    let fm = FileManager.default
    let bundle = Bundle.main.bundleURL
    let old = bundle.deletingLastPathComponent()
      .appendingPathComponent(".\(Self.appName).old.app")
    try? fm.removeItem(at: old)
    do {
      try fm.moveItem(at: bundle, to: old)
      do {
        try fm.moveItem(at: staged, to: bundle)
      } catch {
        try? fm.moveItem(at: old, to: bundle)
        throw error
      }
      try? fm.removeItem(at: old)
    } catch let error as NSError where Self.needsAdmin(error) {
      try installAsAdmin(staged: staged, bundle: bundle, old: old)
    }
    // staged = <staging>/app/Pebble.app; drop the whole staging folder.
    try? fm.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
    try? fm.removeItem(at: stagingDirectory(for: bundle)) // cache fallback
    installedVersion = version
    state = .ready(version)
    onInstalled?(version)
  }

  private func installAsAdmin(staged: URL, bundle: URL, old: URL) throws {
    let s = Self.shellQuote(staged.path)
    let b = Self.shellQuote(bundle.path)
    let o = Self.shellQuote(old.path)
    let script = "rm -rf \(o) && mv \(b) \(o) && if mv \(s) \(b); "
      + "then rm -rf \(o); else mv \(o) \(b); exit 1; fi"
    let apple = script.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    do {
      _ = try Self.run("/usr/bin/osascript", ["-e",
        "do shell script \"\(apple)\" with prompt \"Pebble is updating itself.\" with administrator privileges"])
    } catch {
      try? FileManager.default.moveItem(at: old, to: bundle)
      throw error
    }
  }

  // MARK: Restart

  /// Starts a new copy once this process exits. The next launch is the update.
  func restartNow() {
    let bundle = Bundle.main.bundleURL.path
    let pid = ProcessInfo.processInfo.processIdentifier
    let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(Self.shellQuote(bundle))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try? process.run()
    NSApp.terminate(nil)
  }

  // MARK: Feed

  private func fetchFeed() async throws -> UpdateRelease {
    var request = URLRequest(url: feedURL)
    request.timeoutInterval = 30
    request.setValue("Pebble/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw UpdateError.badFeed
    }
    guard let release = try? JSONDecoder().decode(UpdateRelease.self, from: data),
          Self.parse(release.version) != nil else {
      throw UpdateError.badFeed
    }
    return release
  }

  // MARK: Signature

  /// Accepts `app` only if its signature is intact and, when the running app
  /// has a team, signed by the same one.
  private func verifySignature(of app: URL) throws {
    _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    let current = Self.teamIdentifier(of: Bundle.main.bundleURL)
    let staged = Self.teamIdentifier(of: app)
    if !current.isEmpty && current != staged { throw UpdateError.signatureMismatch }
  }

  private static func teamIdentifier(of app: URL) -> String {
    guard let out = try? run("/usr/bin/codesign", ["-dv", app.path]) else { return "" }
    for line in out.split(separator: "\n") {
      if let value = line.split(separator: "=", maxSplits: 1).last,
         line.contains("TeamIdentifier=") {
        let team = String(value).trimmingCharacters(in: .whitespaces)
        return team == "not set" ? "" : team
      }
    }
    return ""
  }

  // MARK: Paths & guards

  private static let appName = "Pebble"

  private func stagingDirectory(for bundle: URL) -> URL {
    let parent = bundle.deletingLastPathComponent()
    if Self.isWritable(parent) { return parent.appendingPathComponent(".pebble-update") }
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Pebble/update")
    return cache
  }

  /// Why the bundle can't be replaced where it is, or nil when it can:
  /// App Translocation (run straight from Downloads) or a read-only volume.
  private func replacementBlocker(for bundle: URL) -> String? {
    if bundle.path.contains("/AppTranslocation/") { return "translocated" }
    if let readOnly = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly,
       readOnly == true {
      return "read-only"
    }
    return nil
  }

  private static func isWritable(_ dir: URL) -> Bool {
    let probe = dir.appendingPathComponent(".pebble-update-\(UUID().uuidString)")
    do {
      try Data().write(to: probe)
      try FileManager.default.removeItem(at: probe)
      return true
    } catch {
      return false
    }
  }

  private static func needsAdmin(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
    }
    return false
  }

  // MARK: Version & hashing

  /// Whether `a` is a newer semver than `b`; a pre-release sorts before the
  /// release it leads up to.
  static func isNewer(_ a: String, than b: String) -> Bool {
    guard let x = parse(a), let y = parse(b) else { return false }
    for i in 0..<3 where x.version[i] != y.version[i] {
      return x.version[i] > y.version[i]
    }
    switch (x.pre, y.pre) {
    case let (l, r) where l == r: return false
    case ("", _): return true
    case (_, ""): return false
    default: return x.pre > y.pre
    }
  }

  private static func parse(_ raw: String) -> (version: [Int], pre: String)? {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("v") { value.removeFirst() }
    let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    var numbers = parts[0].split(separator: ".")
    guard (1...3).contains(numbers.count) else { return nil }
    while numbers.count < 3 { numbers.append("0") }
    var result: [Int] = []
    for part in numbers {
      guard let n = Int(part), n >= 0 else { return nil }
      result.append(n)
    }
    return (result, parts.count > 1 ? String(parts[1]) : "")
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Process helper

  @discardableResult
  private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 { throw UpdateError.command(output) }
    return output
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
  case badFeed
  case checksumMismatch
  case unpack
  case signatureMismatch
  case stuck(String)
  case command(String)

  var errorDescription: String? {
    switch self {
    case .badFeed:
      return tr("Couldn't read the update feed.", "无法读取更新信息。")
    case .checksumMismatch:
      return tr("The download doesn't match its checksum.", "下载文件校验失败。")
    case .unpack:
      return tr("The downloaded update couldn't be opened.", "无法打开下载的更新。")
    case .signatureMismatch:
      return tr("The update isn't signed by the same developer.", "更新包的签名与当前版本不一致。")
    case .stuck(let reason):
      return reason == "translocated"
        ? tr("Pebble is running from a temporary location. Move it to Applications and try again.",
             "Pebble 正从临时位置运行，请先移到「应用程序」再更新。")
        : tr("Pebble can't be replaced where it is (read-only volume).",
             "Pebble 所在位置不可写（只读卷），无法替换。")
    case .command(let output):
      let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty ? tr("The update failed.", "更新失败。") : detail
    }
  }
}

// MARK: - Downloader

/// A download task with progress, resolving to a file on disk.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
  private let destination: URL
  private let onProgress: (Double) -> Void
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?

  private init(destination: URL, onProgress: @escaping (Double) -> Void) {
    self.destination = destination
    self.onProgress = onProgress
  }

  static func run(url: URL, to destination: URL,
                  onProgress: @escaping (Double) -> Void) async throws {
    let downloader = Downloader(destination: destination, onProgress: onProgress)
    try await downloader.start(url: url)
  }

  private func start(url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.continuation = continuation
      let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
      self.session = session
      session.downloadTask(with: url).resume()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      finish(.success(()))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    Task { @MainActor in onProgress(progress) }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    session?.invalidateAndCancel()
    session = nil
    continuation.resume(with: result)
  }
}