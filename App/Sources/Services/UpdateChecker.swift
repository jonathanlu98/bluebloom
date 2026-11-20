// Checks GitHub Releases for newer stable versions of Blue Bloom (zero third-party dependencies).
// Uses ETag caching (If-None-Match) to stay well within GitHub's unauthenticated rate limit,
// and only ever talks to api.github.com when automatic checks are enabled or the user clicks Check for Updates.
import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let releaseURL: URL
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case failed
}

enum UpdateChecker {
    static let projectURL = URL(string: "https://github.com/jonathanlu98/bluebloom")!
    static let releasesURL = URL(string: "https://github.com/jonathanlu98/bluebloom/releases/latest")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/jonathanlu98/bluebloom/releases/latest")!
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private static let etagKey = "UpdateCheckETag"
    private static let cachedVersionKey = "UpdateCachedVersion"
    private static let cachedURLKey = "UpdateCachedURL"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private enum FetchError: Error {
        case badStatus(Int)
        case invalidPayload
    }

    // Compares semantic versions like "1.2.0" / "v1.2.0" against the current app version.
    // Returns true only when remote is strictly newer than current.
    static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let r = parseVersion(remote), let c = parseVersion(current) else { return false }
        let count = max(r.core.count, c.core.count)
        for i in 0..<count {
            let rv = i < r.core.count ? r.core[i] : 0
            let cv = i < c.core.count ? c.core[i] : 0
            if rv != cv { return rv > cv }
        }
        // Stable release (no pre-release suffix) is newer than a pre-release of the same core version
        return !r.isPrerelease && c.isPrerelease
    }

    static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func parseVersion(_ raw: String) -> (core: [Int], isPrerelease: Bool)? {
        let cleaned = normalizedVersion(raw)
        guard !cleaned.isEmpty else { return nil }
        let withoutBuild = cleaned.split(separator: "+", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        let coreStrings = parts[0].split(separator: ".")
        guard !coreStrings.isEmpty else { return nil }
        var nums: [Int] = []
        for s in coreStrings {
            guard let n = Int(s), n >= 0 else { return nil }
            nums.append(n)
        }
        return (nums, parts.count > 1)
    }

    // Ensure the release URL stays on our GitHub repository before handing it to NSWorkspace
    private static func validatedReleaseURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw),
              url.scheme == "https",
              url.host?.lowercased() == "github.com",
              url.path.lowercased().hasPrefix("/jonathanlu98/bluebloom/")
        else {
            return releasesURL
        }
        return url
    }

    static func check(currentVersion: String, manual: Bool, completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        let defaults = UserDefaults.standard
        var request = URLRequest(url: latestReleaseAPI)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BlueBloom/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if !manual, let etag = defaults.string(forKey: etagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(FetchError.invalidPayload))
                return
            }
            if http.statusCode == 304 {
                if let cached = defaults.string(forKey: cachedVersionKey), !cached.isEmpty {
                    let url = validatedReleaseURL(defaults.string(forKey: cachedURLKey))
                    let release = isNewer(cached, than: currentVersion) ? ReleaseInfo(version: cached, releaseURL: url) : nil
                    completion(.success(release))
                } else {
                    completion(.success(nil))
                }
                return
            }
            guard http.statusCode == 200, let data else {
                completion(.failure(FetchError.badStatus(http.statusCode)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
                if decoded.draft == true || decoded.prerelease == true {
                    completion(.success(nil))
                    return
                }
                let version = normalizedVersion(decoded.tagName)
                guard parseVersion(version) != nil else {
                    completion(.failure(FetchError.invalidPayload))
                    return
                }
                let url = validatedReleaseURL(decoded.htmlURL)
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    defaults.set(etag, forKey: etagKey)
                }
                defaults.set(version, forKey: cachedVersionKey)
                defaults.set(url.absoluteString, forKey: cachedURLKey)
                let release = isNewer(version, than: currentVersion) ? ReleaseInfo(version: version, releaseURL: url) : nil
                completion(.success(release))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }
}
