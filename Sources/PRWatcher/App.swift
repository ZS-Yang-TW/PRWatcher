import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct PRWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The menu bar UI is an NSStatusItem + NSPopover owned by AppDelegate;
    // MenuBarExtra(.window) doesn't shrink when its content gets shorter.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    @MainActor
    private func setUpStatusItem() {
        let store = PRStore.shared
        let host = NSHostingController(rootView: ContentView().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.setAccessibilityLabel("PR Watcher")

        store.$prs
            .map { $0.contains(where: \.unseen) }
            .removeDuplicates()
            .sink { unseen in button.image = StatusIcon.make(badge: unseen) }
            .store(in: &cancellables)

        // Dim the icon while automatic checks are paused.
        store.$paused
            .sink { button.appearsDisabled = $0 }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { setUpStatusItem() }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await PRStore.shared.checkIfOverdue() }
        }
        Task { @MainActor in await PRStore.shared.autoCheck() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Clicking a notification opens the PR in the browser.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
            Task { @MainActor in PRStore.shared.markSeen(url: s) }
        }
        completionHandler()
    }
}

struct ContentView: View {
    @EnvironmentObject var store: PRStore
    @State private var input = ""
    @State private var addError: String?
    @State private var showSettings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.pat.isEmpty || showSettings { settings }
            addField
            Divider()
            list
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Text("PR Watcher").font(.headline)
            Spacer()
            if store.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.checkAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("立即檢查")
                    .disabled(store.pat.isEmpty)
            }
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("設定")
        }
        .buttonStyle(.borderless)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Azure DevOps Personal Access Token（需要 Code: Read）").font(.caption).foregroundStyle(.secondary)
            SecureField("貼上 PAT", text: $store.pat).textFieldStyle(.roundedBorder)
            Picker("檢查間隔", selection: $store.intervalMinutes) {
                ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) 分鐘").tag($0) }
            }
            Toggle("登入時自動啟動", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $input, prompt: Text("貼上 PR 連結"))
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                Button("追蹤", action: add).disabled(input.isEmpty)
            }
            if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var list: some View {
        if store.prs.isEmpty {
            Text("還沒有追蹤任何 PR").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
        } else if store.prs.count <= 3 {
            rows
        } else {
            // ScrollView has no intrinsic height, so give it a fixed one once the list is long.
            ScrollView { rows }.frame(height: 380)
        }
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(store.prs) { PRRow(pr: $0) }
        }
    }

    private var footer: some View {
        HStack {
            Button { store.paused.toggle() } label: {
                Image(systemName: store.paused ? "play.fill" : "pause.fill")
            }
            .help(store.paused ? "繼續自動檢查" : "暫停自動檢查")
            if let last = store.lastRun {
                Text("上次檢查 \(last.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            if store.paused {
                Text("已暫停自動檢查").foregroundStyle(.orange)
            } else if let next = store.nextRun {
                Text("· 下次 \(next.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.unseenCount > 0 {
                Button("全部標為已讀") { store.markAllSeen() }
            }
            Button("結束") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private func add() {
        addError = store.add(input)
        if addError == nil { input = "" }
    }
}

struct PRRow: View {
    @EnvironmentObject var store: PRStore
    let pr: TrackedPR
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if pr.unseen { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                    Text(pr.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(pr.ref.shortName)
                    if let s = pr.snapshot { statusBadge(s) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let votes = pr.snapshot?.votes, !votes.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(votes.sorted(by: { $0.key < $1.key }), id: \.key) { name, vote in
                            Label(name, systemImage: voteIcon(vote))
                                .foregroundStyle(voteColor(vote))
                                .help(AzureDevOps.voteText(vote))
                        }
                    }
                    .font(.caption).lineLimit(1)
                }
                if let error = pr.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if !pr.lastChanges.isEmpty, let date = pr.lastChangeDate {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(pr.lastChanges.prefix(3), id: \.self) { Text("• \($0)").lineLimit(1) }
                        Text("變更於 \(date.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { store.remove(pr) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("停止追蹤")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hovering ? 0.15 : 0.07)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.open(pr) }
    }

    private func statusBadge(_ s: Snapshot) -> some View {
        let text = s.isDraft ? "Draft" : s.status.capitalized
        let color: Color = s.status == "completed" ? .purple : s.status == "abandoned" ? .gray : .green
        return Text(text).padding(.horizontal, 5).background(Capsule().fill(color.opacity(0.2))).foregroundStyle(color)
    }

    private func voteIcon(_ v: Int) -> String {
        switch v {
        case 10, 5: return "checkmark.circle.fill"
        case -5: return "clock.fill"
        case -10: return "xmark.octagon.fill"
        default: return "circle"
        }
    }

    private func voteColor(_ v: Int) -> Color {
        switch v {
        case 10, 5: return .green
        case -5: return .orange
        case -10: return .red
        default: return .secondary
        }
    }
}
