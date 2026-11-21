import Foundation
import SwiftData
import Observation
import UserNotifications

@MainActor protocol ReminderCenter {
    func permission() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: ReminderCenter {
    func permission() async -> UNAuthorizationStatus { await notificationSettings().authorizationStatus }
}

@MainActor @Observable final class TaskStore {
    let context: ModelContext
    var openItems: [Item] = []
    var change = 0
    var errorMessage: String?
    private(set) var preferences: AppPreferences
    private let center: any ReminderCenter
    private var reconciling = false
    private var needsPass = false
    private var requestPermission = false

    init(_ container: ModelContainer, center: any ReminderCenter = UNUserNotificationCenter.current()) throws {
        self.center = center
        let context = ModelContext(container)
        context.autosaveEnabled = false
        self.context = context
        preferences = try context.fetch(FetchDescriptor<SchemaV2.Settings>()).first?.value ?? AppPreferences()
    }

    func savePreferences(_ proposed: AppPreferences) throws {
        let value = try proposed.validated()
        guard value != preferences else { return }
        let follows = ReminderRule.followDefault.rawValue
        let none = DateKind.none.rawValue
        let query = FetchDescriptor<Item>(predicate: #Predicate { !$0.isDone && $0.rule == follows && $0.kind != none })
        let affected = value.advance == preferences.advance ? [] : try context.fetch(query)
        let record = try context.fetch(FetchDescriptor<SchemaV2.Settings>()).first ?? SchemaV2.Settings()
        if record.modelContext == nil { context.insert(record) }
        record.apply(value)
        let now = Date()
        for item in affected {
            if item.reminderStatus == "已安排", let old = item.desiredReminder, old <= now { continue }
            item.resetReminder(now: now, defaultAdvance: value.advance)
        }
        // The preference and the desired notification times commit or roll back together.
        try commit()
        preferences = value
        if !affected.isEmpty { refresh(ask: affected.contains { $0.desiredReminder != nil }) }
    }

    func page(done: Bool, limit: Int) throws -> [Item] {
        var query = FetchDescriptor<Item>(predicate: #Predicate { $0.isDone == done })
        query.sortBy = done ? [SortDescriptor(\.completed, order: .reverse), SortDescriptor(\.id)] :
            [SortDescriptor(\.sortDay), SortDescriptor(\.sortRank), SortDescriptor(\.time), SortDescriptor(\.created), SortDescriptor(\.id)]
        query.fetchLimit = limit
        query.propertiesToFetch = [\.id, \.title, \.hasNotes, \.isDone, \.kind, \.time, \.zone, \.sortDay, \.sortRank, \.completed, \.created,
                                   \.rule, \.desiredReminder, \.reminderStatus]
        return try context.fetch(query)
    }

    func item(id: UUID) throws -> Item? {
        var query = FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    @discardableResult func insert(_ drafts: [Draft]) throws -> [Item] {
        guard !drafts.isEmpty, drafts.allSatisfy(\.valid) else { throw StoreError.emptyTitle }
        let items = drafts.map { Item($0, defaultAdvance: preferences.advance) }
        for item in items { context.insert(item) }
        try commit()
        refresh(ask: items.contains { $0.desiredReminder != nil })
        return items
    }

    func update(_ item: Item, with draft: Draft) throws {
        guard draft.valid else { throw StoreError.emptyTitle }
        let old = item.desiredReminder
        item.apply(draft, defaultAdvance: preferences.advance)
        try commit()
        refresh(ask: item.desiredReminder != nil && item.desiredReminder != old)
    }

    func toggle(_ item: Item) throws {
        item.toggle(defaultAdvance: preferences.advance)
        try commit()
        refresh(ask: item.desiredReminder != nil)
    }

    func remove(_ items: [Item]) throws {
        for item in items { context.delete(item) }
        try commit()
        refresh()
    }

    func commit() throws {
        do { try context.save(); change &+= 1 }
        catch { context.rollback(); throw error }
    }

    func refresh(ask: Bool = false) {
        requestPermission = requestPermission || ask
        needsPass = true
        guard !reconciling else { return }
        reconciling = true
        Task {
            defer { reconciling = false }
            while needsPass {
                needsPass = false
                let ask = requestPermission
                requestPermission = false
                do { try await reconcile(ask: ask) }
                catch { errorMessage = "提醒待安排。\(error.localizedDescription)" }
            }
        }
    }

    private func reconcile(ask: Bool) async throws {
        var permission = await center.permission()
        if ask && permission == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            permission = await center.permission()
        }
        let allowed = [.authorized, .provisional, .ephemeral].contains(permission)
        let pending = await center.pendingNotificationRequests()
        let now = Date()
        let query = FetchDescriptor<Item>(predicate: #Predicate { !$0.isDone && $0.desiredReminder != nil },
                                          sortBy: [SortDescriptor(\.desiredReminder), SortDescriptor(\.created)])
        let items = try context.fetch(query)
        // If permission or a system slot became available too late, recover only
        // requests that never made it into the system. Do not repeat a delivered alert.
        for item in items where (item.desiredReminder ?? .distantPast) <= now && item.reminderStatus != "已安排" {
            item.resetReminder(now: now, defaultAdvance: preferences.advance)
        }
        let future = items.filter { ($0.desiredReminder ?? .distantPast) > now }.sorted {
            $0.desiredReminder! < $1.desiredReminder!
        }
        let owned = pending.filter { $0.identifier.hasPrefix("saywhen.") }
        let capacity = max(0, 64 - (pending.count - owned.count))
        let selected = allowed ? Array(future.prefix(capacity)) : []
        let wanted = Set(selected.map { "saywhen." + $0.id.uuidString })
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !wanted.contains($0) })
        let existing = Dictionary(uniqueKeysWithValues: owned.map { ($0.identifier, $0) })
        var changed = context.hasChanges
        for item in future {
            if needsPass { break }
            let id = "saywhen." + item.id.uuidString
            var status = "提醒待安排"
            if permission == .denied { status = "通知未开启" }
            else if allowed && !wanted.contains(id) { status = "提醒名额已满" }
            if wanted.contains(id), let date = item.desiredReminder {
                let current = existing[id]
                let old = (current?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                let identical = old.map { abs($0.timeIntervalSince(date)) < 1 } == true && current?.content.title == item.title && current?.content.body == "到期：" + item.draft.due.label
                do {
                    if !identical {
                        let content = UNMutableNotificationContent()
                        content.title = item.title
                        content.body = "到期：" + item.draft.due.label
                        content.userInfo = ["id":item.id.uuidString]
                        content.sound = .default
                        var cal = Calendar(identifier: .gregorian)
                        cal.timeZone = TimeZone(secondsFromGMT: 0)!
                        var parts = cal.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date)
                        parts.timeZone = cal.timeZone
                        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                    }
                    status = "已安排"
                } catch {
                    status = "提醒待安排"
                    if current != nil && !needsPass {
                        center.removePendingNotificationRequests(withIdentifiers: [id])
                    }
                }
            }
            if !needsPass && !item.isDeleted && item.reminderStatus != status {
                item.reminderStatus = status
                changed = true
            }
        }
        if changed { try commit() }
        guard !needsPass, allowed, !selected.isEmpty else { return }
        let confirmed = Set(await center.pendingNotificationRequests().map(\.identifier))
        guard !needsPass else { return }
        for item in selected where !confirmed.contains("saywhen." + item.id.uuidString) && (item.desiredReminder ?? .distantPast) > .now && item.reminderStatus == "已安排" {
            item.reminderStatus = "提醒待安排"
        }
        if context.hasChanges { try commit() }
    }
}

enum StoreError: LocalizedError {
    case emptyTitle
    var errorDescription: String? { "请填写待办标题。" }
}

