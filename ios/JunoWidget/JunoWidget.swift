import AppIntents
import SwiftUI
import WidgetKit

// Juno widgets. Figures come from the shared App Group, written by the app
// (lib/core/widget/home_widget_sync.dart). Buttons run LogExpenseIntent
// (ios/Shared/JunoIntents.swift) — they log without opening Juno.

struct Preset: Decodable, Hashable {
    let category: String
    let amount: Double
    let label: String
}

struct JunoEntry: TimelineEntry {
    let date: Date
    let month: String
    let spent: String
    let personal: String
    let household: String
    let pace: String
    let safe: String
    let budgetRatio: Double
    let budgetText: String
    let presets: [Preset]

    static let placeholder = JunoEntry(
        date: .now, month: "OCTOBER", spent: "$2,418", personal: "$1,120", household: "$1,298",
        pace: "$81/day", safe: "$64", budgetRatio: 0.62, budgetText: "62% of a budget used",
        presets: [Preset(category: "Coffee", amount: 4, label: "Coffee $4"),
                  Preset(category: "Groceries", amount: 40, label: "Groceries $40")])
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> JunoEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (JunoEntry) -> Void) {
        completion(context.isPreview ? .placeholder : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JunoEntry>) -> Void) {
        // The app pushes on every change; hourly just rolls the month over.
        completion(Timeline(entries: [read()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func read() -> JunoEntry {
        let d = UserDefaults(suiteName: junoAppGroup)
        var presets: [Preset] = []
        if let raw = d?.string(forKey: "presets"), let data = raw.data(using: .utf8) {
            presets = (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
        }
        return JunoEntry(
            date: .now,
            month: d?.string(forKey: "month") ?? "",
            spent: d?.string(forKey: "spent") ?? "$0",
            personal: d?.string(forKey: "personal") ?? "$0",
            household: d?.string(forKey: "household") ?? "$0",
            pace: d?.string(forKey: "pace") ?? "",
            safe: d?.string(forKey: "safe") ?? "",
            budgetRatio: d?.double(forKey: "budgetRatio") ?? 0,
            budgetText: d?.string(forKey: "budgetText") ?? "",
            presets: presets)
    }
}

// Tokens mirrored from lib/core/ui/tokens.dart.
enum J {
    static let bg = Color(light: 0xFFFFFF, dark: 0x0E0B0B)
    static let ink = Color(light: 0x15171A, dark: 0xFBF5EA)
    static let muted = Color(light: 0x3A3D42, dark: 0xFBF5EA, darkAlpha: 0.6)
    static let faint = Color(light: 0x7A7D83, dark: 0xFBF5EA, darkAlpha: 0.36)
    static let hairline = Color(light: 0xE7E3DC, dark: 0xFBF5EA, darkAlpha: 0.12)
    static let brand = Color(light: 0x8C3839, dark: 0xC9686A)
    static let household = Color(light: 0x008AA0, dark: 0x1FA89E)
    static let warn = Color(light: 0x9A6700, dark: 0xE3B341)
    static let over = Color(light: 0xCF2E1F, dark: 0xF4553D)
    static let ok = Color(light: 0x1A7F37, dark: 0x3FB950)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, darkAlpha: Double = 1) {
        self.init(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let a = trait.userInterfaceStyle == .dark ? darkAlpha : 1
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        })
    }
}

private struct CapsLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(J.mono(9, .medium)).tracking(1.1).foregroundStyle(J.faint)
    }
}

struct BudgetBar: View {
    let ratio: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(J.hairline)
                Rectangle()
                    .fill(ratio >= 1 ? J.over : ratio >= 0.8 ? J.warn : J.ok)
                    .frame(width: g.size.width * min(max(ratio, 0), 1))
            }
        }.frame(height: 3)
    }
}

struct SmallView: View {
    let e: JunoEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(J.brand).frame(width: 22, height: 2)
            CapsLabel(text: "Spent · \(e.month)")
            Text(e.spent).font(J.mono(26)).tracking(-1.2).foregroundStyle(J.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(e.safe.isEmpty ? e.pace : "\(e.safe) safe today").font(J.mono(11, .medium)).foregroundStyle(J.muted)
            Spacer(minLength: 0)
            BudgetBar(ratio: e.budgetRatio)
        }
    }
}

/// One-tap logging: runs the intent in place — Juno stays closed.
struct PresetButton: View {
    let preset: Preset
    var body: some View {
        Button(intent: LogExpenseIntent(amount: preset.amount, category: preset.category)) {
            Text(preset.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(J.ink)
        .background(Capsule().strokeBorder(J.hairline))
    }
}

struct Split: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                CapsLabel(text: label)
            }
            Text(value).font(J.mono(15)).foregroundStyle(J.ink)
        }
    }
}

struct MediumView: View {
    let e: JunoEntry
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SmallView(e: e)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Split(label: "Personal", value: e.personal, color: J.brand)
                    Split(label: "Household", value: e.household, color: J.household)
                }
                Spacer(minLength: 0)
                ForEach(e.presets.prefix(2), id: \.self) { PresetButton(preset: $0) }
                Link(destination: URL(string: "juno://add")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New entry").font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(J.bg)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(J.brand))
                }
            }
        }
    }
}

// Lock Screen / StandBy: system-tinted, so no custom colours.
struct AccessoryView: View {
    @Environment(\.widgetFamily) var family
    let e: JunoEntry
    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(max(e.budgetRatio, 0), 1)) {
                Image(systemName: "creditcard")
            } currentValueLabel: {
                Text(e.spent.replacingOccurrences(of: "$", with: "")).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryInline:
            Text("Juno · \(e.spent) spent")
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("SPENT · \(e.month)").font(.system(size: 10, weight: .medium, design: .monospaced))
                Text(e.spent).font(.system(size: 20, weight: .semibold, design: .monospaced))
                Text(e.safe.isEmpty ? e.budgetText : "\(e.safe) safe to spend today").font(.system(size: 11))
            }
        }
    }
}

struct JunoWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: JunoEntry
    var body: some View {
        Group {
            switch family {
            case .systemMedium: MediumView(e: entry)
            case .accessoryCircular, .accessoryRectangular, .accessoryInline: AccessoryView(e: entry)
            default: SmallView(e: entry)
            }
        }
        .containerBackground(J.bg, for: .widget)
        .widgetURL(URL(string: "juno://add"))
    }
}

struct JunoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JunoWidget", provider: Provider()) { entry in
            JunoWidgetView(entry: entry)
        }
        .configurationDisplayName("Juno")
        .description("This month's spending, safe-to-spend, and one-tap logging.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Control Center / Action Button control (iOS 18): opens a new entry.
@available(iOS 18.0, *)
struct JunoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "JunoQuickAdd") {
            ControlWidgetButton(action: OpenQuickAddIntent()) {
                Label("New entry", systemImage: "plus.circle")
            }
        }
        .displayName("Juno: new entry")
        .description("Open Juno's add sheet.")
    }
}

@main
struct JunoWidgets: WidgetBundle {
    var body: some Widget {
        JunoWidget()
        if #available(iOS 18.0, *) {
            JunoControl()
        }
    }
}
