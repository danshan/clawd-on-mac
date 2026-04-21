import Foundation

struct SkillsShSkill: Codable {
    let id: String
    let skillId: String
    let name: String
    let source: String
    let installs: Int
}

enum LeaderboardType: String {
    case allTime = "alltime"
    case trending = "trending"
    case hot = "hot"

    func url(base: String) -> URL {
        switch self {
        case .allTime: return URL(string: base.hasSuffix("/") ? base : base + "/")!
        case .trending: return URL(string: base.hasSuffix("/") ? "\(base)trending" : "\(base)/trending")!
        case .hot: return URL(string: base.hasSuffix("/") ? "\(base)hot" : "\(base)/hot")!
        }
    }
}

final class SkillsMarketplace {

    enum Error: LocalizedError {
        case httpError(statusCode: Int)
        case parsingFailed(String)

        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "HTTP request failed with status \(code)"
            case .parsingFailed(let msg): return "Parsing failed: \(msg)"
            }
        }
    }

    static let defaultBaseURL = "https://skills.sh"

    private let session: URLSession
    private let db: SkillDatabase?

    init(db: SkillDatabase? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "ClawdOnMac"]
        self.session = URLSession(configuration: config)
        self.db = db
    }

    private var baseURL: String {
        if let db = db, let url = try? db.getSetting("marketplace_url"), !url.isEmpty {
            return url
        }
        return Self.defaultBaseURL
    }

    func fetchLeaderboard(type: LeaderboardType) async throws -> [SkillsShSkill] {
        let html = try await fetchString(url: type.url(base: baseURL))
        return parseLeaderboardHTML(html)
    }

    func searchSkills(query: String, limit: Int = 20) async throws -> [SkillsShSkill] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let url = URL(string: "\(base)/api/search?q=\(encoded)&limit=\(limit)")!
        let data = try await fetchData(url: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let arr = json as? [[String: Any]] {
            return parseSkillsArray(arr)
        }
        if let dict = json as? [String: Any], let arr = dict["skills"] as? [[String: Any]] {
            return parseSkillsArray(arr)
        }
        return []
    }

    // MARK: - Private

    private func fetchString(url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(statusCode: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw Error.parsingFailed("Response is not valid UTF-8")
        }
        return html
    }

    private func fetchData(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(statusCode: http.statusCode)
        }
        return data
    }

    private func parseLeaderboardHTML(_ html: String) -> [SkillsShSkill] {
        if let skills = parseNextData(html), !skills.isEmpty {
            return skills
        }
        return parseEmbeddedSkillObjects(html)
    }

    // MARK: - __NEXT_DATA__ parsing

    private func parseNextData(_ html: String) -> [SkillsShSkill]? {
        let marker = #"<script id="__NEXT_DATA__" type="application/json">"#
        guard let markerRange = html.range(of: marker) else { return nil }
        let afterMarker = html[markerRange.upperBound...]
        guard let endRange = afterMarker.range(of: "</script>") else { return nil }
        let jsonStr = String(afterMarker[..<endRange.lowerBound])

        guard let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any] else {
            return nil
        }

        let arr = (pageProps["initialSkills"] as? [[String: Any]])
            ?? (pageProps["skills"] as? [[String: Any]])
            ?? (pageProps["items"] as? [[String: Any]])

        guard let skillsArr = arr else { return nil }
        return parseSkillsArray(skillsArr)
    }

    // MARK: - Regex fallback

    private func parseEmbeddedSkillObjects(_ html: String) -> [SkillsShSkill] {
        // Primary pattern: handles escaped quotes in RSC payloads
        let primary = #"(?:\\)?"source(?:\\)?":(?:\\)?"([^"\\]+)(?:\\)?",(?:[^{}]|\\.)*?(?:(?:\\)?"skillId(?:\\)?"|(?:\\)?"skill_id(?:\\)?"):(?:\\)?"([^"\\]+)(?:\\)?",(?:[^{}]|\\.)*?(?:\\)?"name(?:\\)?":(?:\\)?"([^"\\]*)(?:\\)?",(?:[^{}]|\\.)*?(?:\\)?"installs(?:\\)?":(\d+)"#

        var skills = parseEmbeddedWithRegex(html, pattern: primary)
        if skills.isEmpty {
            // Fallback: plain JSON objects
            let fallback = #"\{"source":"([^"]+)","skill_id":"([^"]+)"(?:,"name":"([^"]*)")?(?:.*?"installs":(\d+))?\}"#
            skills = parseEmbeddedWithRegex(html, pattern: fallback)
        }
        return skills
    }

    private func parseEmbeddedWithRegex(_ html: String, pattern: String) -> [SkillsShSkill] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        var seen = Set<String>()
        var skills: [SkillsShSkill] = []

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let sourceRange = Range(match.range(at: 1), in: html),
                  let skillIdRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let source = String(html[sourceRange]).replacingOccurrences(of: #"\""#, with: "\"")
            let skillId = String(html[skillIdRange]).replacingOccurrences(of: #"\""#, with: "\"")

            let id = "\(source)/\(skillId)"
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            var name = skillId
            if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
               let nameRange = Range(match.range(at: 3), in: html) {
                let parsed = String(html[nameRange]).replacingOccurrences(of: #"\""#, with: "\"")
                if !parsed.isEmpty { name = parsed }
            }

            var installs = 0
            if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound,
               let installsRange = Range(match.range(at: 4), in: html) {
                installs = Int(html[installsRange]) ?? 0
            }

            skills.append(SkillsShSkill(
                id: id,
                skillId: skillId,
                name: name,
                source: source,
                installs: installs
            ))
        }
        return skills
    }

    // MARK: - Shared array parser

    private func parseSkillsArray(_ arr: [[String: Any]]) -> [SkillsShSkill] {
        var seen = Set<String>()
        var skills: [SkillsShSkill] = []

        for item in arr {
            guard let source = item["source"] as? String, !source.isEmpty else { continue }

            let skillId: String
            if let v = item["skillId"] as? String {
                skillId = v
            } else if let v = item["skill_id"] as? String {
                skillId = v
            } else if let v = item["id"] as? String {
                skillId = v
            } else {
                continue
            }
            guard !skillId.isEmpty else { continue }

            let id = "\(source)/\(skillId)"
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let name: String
            if let n = item["name"] as? String, !n.isEmpty {
                name = n
            } else {
                name = skillId
            }
            let installs = (item["installs"] as? Int) ?? 0

            skills.append(SkillsShSkill(
                id: id,
                skillId: skillId,
                name: name,
                source: source,
                installs: installs
            ))
        }
        return skills
    }
}
