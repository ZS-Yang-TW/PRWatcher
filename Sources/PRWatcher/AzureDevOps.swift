import Foundation

/// Identifies one Azure DevOps pull request parsed from its web URL.
struct PRRef: Codable, Hashable {
    let baseURL: String   // https://dev.azure.com/{org} or https://{org}.visualstudio.com
    let project: String
    let repo: String
    let prId: Int

    var apiURL: String { "\(baseURL)/\(project)/_apis/git/repositories/\(repo)/pullrequests/\(prId)" }
    var shortName: String { "\(repo.removingPercentEncoding ?? repo) !\(prId)" }

    static func parse(_ raw: String) -> PRRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        let patterns = [
            #"^(https://dev\.azure\.com/[^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(\d+)"#,
            #"^(https://[^./]+\.visualstudio\.com(?:/DefaultCollection)?)/([^/]+)/_git/([^/]+)/pullrequest/(\d+)"#,
        ]
        for p in patterns {
            let re = try! NSRegularExpression(pattern: p, options: .caseInsensitive)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ i: Int) -> String { String(s[Range(m.range(at: i), in: s)!]) }
            return PRRef(baseURL: g(1), project: g(2), repo: g(3), prId: Int(g(4))!)
        }
        return nil
    }
}

/// The parts of a PR we compare between checks to detect updates.
struct Snapshot: Codable, Equatable {
    var title: String
    var status: String
    var isDraft: Bool
    var votes: [String: Int]        // reviewer display name → vote
    var commentKeys: Set<String>    // "threadId-commentId" of human comments
}

struct NewComment {
    let author: String
    let content: String
}

struct FetchResult {
    let snapshot: Snapshot
    let comments: [String: NewComment]   // keyed like Snapshot.commentKeys
}

enum AzureError: LocalizedError {
    case unauthorized
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "PAT 無效、過期或沒有 Code (Read) 權限"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

enum AzureDevOps {
    private struct PRResponse: Decodable {
        let title: String
        let status: String
        let isDraft: Bool?
        let reviewers: [Reviewer]?
        struct Reviewer: Decodable { let displayName: String; let vote: Int }
    }

    private struct ThreadsResponse: Decodable {
        let value: [Thread]
        struct Thread: Decodable { let id: Int; let isDeleted: Bool?; let comments: [Comment]? }
        struct Comment: Decodable {
            let id: Int
            let content: String?
            let commentType: String?
            let isDeleted: Bool?
            let author: Author
        }
        struct Author: Decodable { let id: String; let displayName: String }
    }

    private struct ConnectionData: Decodable {
        let authenticatedUser: User
        struct User: Decodable { let id: String }
    }

    static func fetch(_ ref: PRRef, pat: String, selfId: String?) async throws -> FetchResult {
        async let pr: PRResponse = get("\(ref.apiURL)?api-version=7.1", pat: pat)
        async let threads: ThreadsResponse = get("\(ref.apiURL)/threads?api-version=7.1", pat: pat)
        let (p, t) = try await (pr, threads)

        var comments: [String: NewComment] = [:]
        for thread in t.value where thread.isDeleted != true {
            for c in thread.comments ?? [] where c.isDeleted != true && c.commentType == "text" {
                // Your own replies are not "updates" worth notifying about.
                if let selfId, c.author.id == selfId { continue }
                comments["\(thread.id)-\(c.id)"] = NewComment(author: c.author.displayName, content: c.content ?? "")
            }
        }
        let votes = Dictionary((p.reviewers ?? []).map { ($0.displayName, $0.vote) }, uniquingKeysWith: { a, _ in a })
        let snap = Snapshot(title: p.title, status: p.status, isDraft: p.isDraft ?? false,
                            votes: votes, commentKeys: Set(comments.keys))
        return FetchResult(snapshot: snap, comments: comments)
    }

    /// The id of the user who owns the PAT, used to ignore your own comments.
    static func currentUserId(baseURL: String, pat: String) async -> String? {
        let data: ConnectionData? = try? await get("\(baseURL)/_apis/connectionData", pat: pat)
        return data?.authenticatedUser.id
    }

    private static func get<T: Decodable>(_ urlString: String, pat: String) async throws -> T {
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Basic " + Data(":\(pat.trimmingCharacters(in: .whitespacesAndNewlines))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Azure DevOps answers a bad PAT with 203 + an HTML sign-in page instead of 401.
        if code == 401 || code == 203 { throw AzureError.unauthorized }
        guard (200..<300).contains(code) else { throw AzureError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func voteText(_ vote: Int) -> String {
        switch vote {
        case 10: return "Approved"
        case 5: return "Approved with suggestions"
        case -5: return "Waiting for author"
        case -10: return "Rejected"
        default: return "No vote"
        }
    }

    /// Human-readable list of what changed between two snapshots.
    static func describeChanges(old: Snapshot, new: FetchResult) -> [String] {
        let snap = new.snapshot
        var lines: [String] = []
        if old.status != snap.status { lines.append("狀態變更：\(old.status) → \(snap.status)") }
        if old.isDraft && !snap.isDraft { lines.append("已從 Draft 發布") }
        for (name, vote) in snap.votes.sorted(by: { $0.key < $1.key }) {
            let before = old.votes[name]
            if before == nil && vote == 0 {
                lines.append("新增 reviewer：\(name)")
            } else if (before ?? 0) != vote {
                lines.append("\(name)：\(voteText(vote))")
            }
        }
        for key in snap.commentKeys.subtracting(old.commentKeys).sorted() {
            guard let c = new.comments[key] else { continue }
            let text = c.content.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(c.author) 留言：\(text.prefix(80))")
        }
        return lines
    }
}
