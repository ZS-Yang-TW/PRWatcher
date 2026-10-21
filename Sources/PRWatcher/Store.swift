import AppKit
import Foundation
import Security
import UserNotifications

struct TrackedPR: Codable, Identifiable {
    var id: String { url }
    let url: String
    let ref: PRRef
    var snapshot: Snapshot?
    var lastChecked: Date?
    var lastChanges: [String] = []
    var lastChangeDate: Date?
    var unseen = false
    var error: String?

    var displayTitle: String { snapshot?.title ?? ref.shortName }
}

@MainActor
final class PRStore: ObservableObject {
    static let shared = PRStore()

    @Published private(set) var prs: [TrackedPR] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastRun: Date?
    @Published var pat: String {
        didSet { Keychain.save(pat) }
    }
    @Published var intervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(intervalMinutes, forKey: "intervalMinutes")
            startTimer()
        }
    }

    /// Stops automatic checks (timer, wake, launch); manual refresh still works.
    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            if !paused { Task { await checkIfOverdue() } }
        }
    }

    private var timer: Timer?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRWatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prs.json")
    }()

    var unseenCount: Int { prs.filter(\.unseen).count }
    var nextRun: Date? { lastRun?.addingTimeInterval(TimeInterval(intervalMinutes * 60)) }

    private init() {
        pat = Keychain.load() ?? ""
        let saved = UserDefaults.standard.integer(forKey: "intervalMinutes")
        intervalMinutes = saved > 0 ? saved : 20
        paused = UserDefaults.standard.bool(forKey: "paused")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TrackedPR].self, from: data) {
            prs = decoded
        }
        startTimer()
    }

    // MARK: - List management

    func add(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ref = PRRef.parse(url) else { return "看不懂這個連結，請貼 Azure DevOps 的 pullrequest 網址" }
        guard !prs.contains(where: { $0.ref == ref }) else { return "這個 PR 已經在清單裡了" }
        prs.append(TrackedPR(url: url, ref: ref))
        save()
        Task { await checkAll() }
        return nil
    }

    func remove(_ pr: TrackedPR) {
        prs.removeAll { $0.id == pr.id }
        save()
    }

    func open(_ pr: TrackedPR) {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        markSeen(url: pr.url)
    }

    func markSeen(url: String) {
        guard let i = prs.firstIndex(where: { $0.url == url }), prs[i].unseen else { return }
        prs[i].unseen = false
        save()
    }

    func markAllSeen() {
        for i in prs.indices { prs[i].unseen = false }
        save()
    }

    // MARK: - Polling

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { _ in
            Task { @MainActor in await PRStore.shared.autoCheck() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called after the Mac wakes: catch up if a scheduled check was missed while asleep.
    func checkIfOverdue() async {
        if let next = nextRun, next > Date() { return }
        await autoCheck()
    }

    func autoCheck() async {
        guard !paused else { return }
        await checkAll()
    }

    func checkAll() async {
        guard !pat.isEmpty, !isChecking else { return }
        isChecking = true
        // Restart the timer so the next automatic check really happens at nextRun,
        // including after a manual refresh.
        defer { isChecking = false; lastRun = Date(); startTimer() }

        var selfIds: [String: String] = [:]
        for base in Set(prs.map(\.ref.baseURL)) {
            selfIds[base] = await AzureDevOps.currentUserId(baseURL: base, pat: pat)
        }

        for pr in prs {
            let result: Result<FetchResult, Error>
            do {
                result = .success(try await AzureDevOps.fetch(pr.ref, pat: pat, selfId: selfIds[pr.ref.baseURL]))
            } catch {
                result = .failure(error)
            }
            // The list may have changed while we were awaiting the network.
            guard let i = prs.firstIndex(where: { $0.id == pr.id }) else { continue }
            prs[i].lastChecked = Date()
            switch result {
            case .failure(let error):
                prs[i].error = error.localizedDescription
            case .success(let fetched):
                prs[i].error = nil
                if let old = prs[i].snapshot {
                    let changes = AzureDevOps.describeChanges(old: old, new: fetched)
                    if !changes.isEmpty {
                        prs[i].lastChanges = changes
                        prs[i].lastChangeDate = Date()
                        prs[i].unseen = true
                        notify(title: fetched.snapshot.title, lines: changes, url: pr.url)
                    }
                }
                prs[i].snapshot = fetched.snapshot
            }
        }
        save()
    }

    private func notify(title: String, lines: [String], url: String) {
        let content = UNMutableNotificationContent()
        content.title = "PR 有更新"
        content.subtitle = title
        content.body = lines.prefix(3).joined(separator: "\n") + (lines.count > 3 ? "\n…等 \(lines.count) 項更新" : "")
        content.sound = .default
        content.userInfo = ["url": url]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PRWatcher",
        kSecAttrAccount as String: "azure-devops-pat",
    ]

    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
