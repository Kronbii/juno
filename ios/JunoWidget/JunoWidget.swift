import SwiftUI
import WidgetKit

// Juno home-screen widget. Reads the figures the app writes to the shared
// App Group (see lib/core/widget/home_widget_sync.dart). Tapping the widget
// opens juno://add, the same quick-add sheet as Back Tap.

private let appGroup = "group.com.kronbii.juno"

struct JunoEntry: TimelineEntry {
    let date: Date
    let month: String
    let spent: String
    let personal: String
    let household: String
    let pace: String
    let budgetRatio: Double
    let budgetText: String

    static let placeholder = JunoEntry(
        date: .now, month: "OCTOBER", spent: "$2,418", personal: "$1,120",
        household: "$1,298", pace: "$81/day", budgetRatio: 0.62, budgetText: "62% of a budget used")
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> JunoEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (JunoEntry) -> Void) {
        completion(context.isPreview ? .placeholder : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JunoEntry>) -> Void) {
        // The app pushes updates on every change; the hourly refresh just
        // rolls the month over if Juno hasn't been opened.
        completion(Timeline(entries: [read()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func read() -> JunoEntry {
        let d = UserDefaults(suiteName: appGroup)
        return JunoEntry(
            date: .now,
            month: d?.string(forKey: "month") ?? "",
            spent: d?.string(forKey: "spent") ?? "$0",
            personal: d?.string(forKey: "personal") ?? "$0",
            household: d?.string(forKey: "household") ?? "$0",
            pace: d?.string(forKey: "pace") ?? "",
            budgetRatio: d?.double(forKey: "budgetRatio") ?? 0,
            budgetText: d?.string(forKey: "budgetText") ?? "")
    }
}

// Tokens mirrored from lib/core/ui/tokens.dart.
private enum J {
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

private extension Color {
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

private struct Label: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(J.mono(9, .medium)).tracking(1.1).foregroundStyle(J.faint)
    }
}

struct SmallView: View {
    let e: JunoEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(J.brand).frame(width: 22, height: 2)
            Label(text: "Spent · \(e.month)")
            Text(e.spent).font(J.mono(26)).tracking(-1.2).foregroundStyle(J.ink)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(e.pace).font(J.mono(11, .medium)).foregroundStyle(J.muted)
            Spacer(minLength: 0)
            BudgetBar(ratio: e.budgetRatio)
        }
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

struct MediumView: View {
    let e: JunoEntry
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SmallView(e: e)
            VStack(alignment: .leading, spacing: 10) {
                Split(label: "Personal", value: e.personal, color: J.brand)
                Split(label: "Household", value: e.household, color: J.household)
                Spacer(minLength: 0)
                Link(destination: URL(string: "juno://add")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New entry").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(J.bg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(J.brand))
                }
            }
        }
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
                Label(text: label)
            }
            Text(value).font(J.mono(16)).foregroundStyle(J.ink)
        }
    }
}

struct JunoWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: JunoEntry
    var body: some View {
        Group {
            if family == .systemMedium { MediumView(e: entry) } else { SmallView(e: entry) }
        }
        .containerBackground(J.bg, for: .widget)
        .widgetURL(URL(string: "juno://add"))
    }
}

@main
struct JunoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JunoWidget", provider: Provider()) { entry in
            JunoWidgetView(entry: entry)
        }
        .configurationDisplayName("Juno")
        .description("This month's spending, and one tap to log an expense.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
