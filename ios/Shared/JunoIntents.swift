import AppIntents
import Foundation

// Juno App Intents — log money without opening the app.
//
// Used by Siri ("Log an expense in Juno"), the Shortcuts app, Back Tap, the
// Action Button, and the widget's buttons. Each run appends one JSON entry to
// an inbox in the shared App Group; Juno imports it on its next launch or
// resume (lib/core/ios/intent_inbox.dart — keep the two in sync).
//
// Built into the Runner target (and the JunoWidget target, if you add one).

let junoAppGroup = "group.com.kronbii.juno"

// MARK: - Inbox

enum JunoInbox {
    static let key = "juno.inbox"

    /// Appends an entry. UserDefaults is shared with the app through the
    /// App Group; home_widget reads the same key from Flutter.
    static func append(_ entry: [String: Any]) {
        guard let defaults = UserDefaults(suiteName: junoAppGroup) else { return }
        var list: [[String: Any]] = []
        if let raw = defaults.string(forKey: key),
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            list = parsed
        }
        list.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: list),
           let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: key)
        }
    }

    static func entry(amount: Double?, currency: String?, category: String?, scope: String?,
                      type: String?, note: String?, text: String?) -> [String: Any] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss" // local time, no zone: Juno uses the local day
        var e: [String: Any] = ["id": UUID().uuidString.lowercased(), "at": f.string(from: Date())]
        if let amount { e["amount"] = amount }
        if let currency { e["currency"] = currency }
        if let category { e["category"] = category }
        if let scope { e["scope"] = scope }
        if let type { e["type"] = type }
        if let note, !note.isEmpty { e["note"] = note }
        if let text, !text.isEmpty { e["text"] = text }
        return e
    }
}

// MARK: - Catalog (categories Juno publishes for Siri)

struct JunoCatalog: Decodable {
    struct Cat: Decodable { let name: String; let kind: String; let scope: String }
    let categories: [Cat]
    let currencies: [String]

    static func load() -> JunoCatalog {
        guard let raw = UserDefaults(suiteName: junoAppGroup)?.string(forKey: "juno.catalog"),
              let data = raw.data(using: .utf8),
              let c = try? JSONDecoder().decode(JunoCatalog.self, from: data)
        else { return JunoCatalog(categories: [], currencies: ["USD"]) }
        return c
    }
}

struct CategoryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category")
    static var defaultQuery = CategoryQuery()

    var id: String { name }
    let name: String
    let kind: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CategoryQuery: EntityStringQuery {
    private func all() -> [CategoryEntity] {
        JunoCatalog.load().categories.map { CategoryEntity(name: $0.name, kind: $0.kind) }
    }

    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        let q = string.lowercased()
        return all().filter { $0.name.lowercased().contains(q) }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        all().filter { $0.kind == "expense" }
    }
}

enum ScopeOption: String, AppEnum {
    case personal, household, other
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "For")
    static var caseDisplayRepresentations: [ScopeOption: DisplayRepresentation] = [
        .personal: "Personal",
        .household: "Household",
        .other: "Other",
    ]
}

enum CurrencyOption: String, AppEnum {
    case usd = "USD", lbp = "LBP"
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Currency")
    static var caseDisplayRepresentations: [CurrencyOption: DisplayRepresentation] = [
        .usd: "US dollars",
        .lbp: "Lebanese pounds",
    ]
}

// MARK: - Intents

/// The Back Tap action: always asks how much, what it was and who it was
/// for, in that order (all three required, so iPhone asks every time). Juno
/// picks the category from what it was — your history, keywords, then the
/// AI — when it imports the entry.
struct LogPurchaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log purchase"
    static var description = IntentDescription(
        "Asks how much, what it was and who it was for, and adds it to Juno without opening it. "
            + "Juno picks the category from what you wrote.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", requestValueDialog: "How much?")
    var amount: Double

    @Parameter(title: "What was it", requestValueDialog: "What was it?")
    var note: String

    @Parameter(title: "Who for", requestValueDialog: "Who for?")
    var scope: ScopeOption

    @Parameter(title: "Currency", default: .usd)
    var currency: CurrencyOption

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) for \(\.$note), \(\.$scope)") {
            \.$currency
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        JunoInbox.append(JunoInbox.entry(
            amount: amount, currency: currency.rawValue, category: nil,
            scope: scope.rawValue, type: "expense", note: note, text: nil))
        let money = currency == .lbp
            ? "LBP \(Int(amount).formatted())"
            : amount.formatted(.currency(code: "USD"))
        return .result(dialog: "Logged \(money) · \(note) · \(scope.rawValue.capitalized). Juno files it when you next open it.")
    }
}

/// "Log expense" — amount, optional category and who it was for. Also the
/// widget's one-tap buttons, which can't ask anything.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log expense"
    static var description = IntentDescription("Adds an expense to Juno without opening it.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", requestValueDialog: "How much?")
    var amount: Double

    @Parameter(title: "Currency", default: .usd)
    var currency: CurrencyOption

    @Parameter(title: "Category", requestValueDialog: "What for?")
    var category: CategoryEntity?

    @Parameter(title: "For", requestValueDialog: "Who for?")
    var scope: ScopeOption?

    // Left without a category, Juno files the entry from this note.
    @Parameter(title: "Note", requestValueDialog: "What was it?")
    var note: String?

    init() {}

    init(amount: Double, category: String?, currency: CurrencyOption = .usd) {
        self.amount = amount
        self.currency = currency
        self.category = category.map { CategoryEntity(name: $0, kind: "expense") }
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) \(\.$currency) on \(\.$category)") {
            \.$scope
            \.$note
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        JunoInbox.append(JunoInbox.entry(
            amount: amount, currency: currency.rawValue, category: category?.name,
            scope: scope?.rawValue, type: "expense", note: note, text: nil))
        let money = currency == .lbp
            ? "LBP \(Int(amount).formatted())"
            : amount.formatted(.currency(code: "USD"))
        let what = category.map { " · \($0.name)" } ?? ""
        let who = scope.map { " · \($0.rawValue.capitalized)" } ?? ""
        return .result(dialog: "Logged \(money)\(what)\(who).")
    }
}

/// "Tell Juno what I spent" — one sentence, parsed by Juno like the add
/// sheet's quick line ("40k taxi yesterday", "salary 5200").
struct LogByTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Log by sentence"
    static var description = IntentDescription("Say or type it naturally, e.g. “12 coffee kalei” or “40k taxi yesterday”.")
    static var openAppWhenRun = false

    @Parameter(title: "What you spent", requestValueDialog: "What did you spend?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        JunoInbox.append(JunoInbox.entry(
            amount: nil, currency: nil, category: nil, scope: nil, type: nil, note: nil, text: text))
        return .result(dialog: "Got it — “\(text)” is in Juno.")
    }
}

/// Opens Juno's add sheet (Control Center, Action Button fallback).
@available(iOS 18.0, *)
struct OpenQuickAddIntent: AppIntent {
    static var title: LocalizedStringResource = "New Juno entry"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "juno://add")!))
    }
}

// MARK: - Siri phrases

struct JunoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPurchaseIntent(),
            phrases: [
                "Log a purchase in \(.applicationName)",
                "Log an expense in \(.applicationName)",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Log purchase",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "Log a \(\.$category) expense in \(.applicationName)",
            ],
            shortTitle: "Log expense",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: LogByTextIntent(),
            phrases: [
                "Tell \(.applicationName) what I spent",
                "Log in \(.applicationName) by voice",
            ],
            shortTitle: "Log by sentence",
            systemImageName: "text.bubble"
        )
    }
}
