# Juno.

A personal and household finance tracker for the Linux desktop and iPhone. It's local-first, and Supabase sync is optional.

- **Track** expenses, income and transfers across accounts. Every entry is marked **Personal** or **Household**, so you can see how much goes to each.
- **Insights:** where your money went this month, what changed compared with the same point last month, six-month trends, top places, and recurring costs.
- **Plan:** monthly budgets per category or per scope, savings goals with contributions, and recurring entries that log themselves on their due date.
- **Import** a bank CSV. Juno guesses the columns, learns your categories, skips rows it has already seen, and lets you undo an import. **Export** writes everything to CSV.
- **Log without opening the app:** App Intents for Siri ("Log an expense in Juno"), Shortcuts, Back Tap and the Action Button. Entries land in a shared inbox that Juno imports on its next launch. See [docs/ios-setup.md](docs/ios-setup.md) and [docs/back-tap-shortcut.md](docs/back-tap-shortcut.md).
- **Currencies:** accounts can hold LBP (or EUR and others) at rates you set. Totals stay in USD, and each entry keeps the USD value it was logged at.
- **Tags** cut across categories, for things like `#trip-istanbul` or `#gift`. You can filter Activity by tag, and Insights totals spending per tag.
- **Receipts:** attach a photo to any entry (camera or library on iPhone, a file on desktop). Receipts sync through Supabase Storage.
- **Net worth over time:** a 12-month history rebuilt from your accounts and entries.
- **Reminders:** a notification on the day a recurring bill is due, plus budget alerts at 80% and 100%.
- **Face ID lock** (iPhone): Juno asks on open and after a minute in the background.
- **Home-screen widget** (iPhone): shows this month's spending and opens a new entry on tap. It has one-tap logging buttons, Lock Screen sizes and a Control Center control. Setup is in [docs/ios-setup.md](docs/ios-setup.md).
- **Excel and Notion imports:** `.xlsx` workbooks (with a sheet picker) and Notion CSV exports. If the file has a Category column, its values are matched to your categories.

## Run

Requires Flutter ≥ 3.38.

```sh
flutter pub get
dart run build_runner build          # drift codegen, after any table change
flutter run -d linux                 # desktop
flutter run -d <your-iphone>         # on the Mac, see below
```

Keyboard shortcuts on desktop:
- `N` opens a new entry.
- `Ctrl+1`…`5` switch tabs.
- In the entry sheet, type digits directly and press `Enter` to save.

Debug builds have **Settings → Data → Load sample data**, which adds four months of demo entries so you can explore the app.

## Sync (optional)

Without configuration Juno runs local-only. To sync your desktop and phone:

1. Create a Supabase project.
2. Run the migrations in [`supabase/migrations/`](supabase/migrations/) in order, either in the SQL editor or with `npx supabase db push` (timestamped files, linked project). They create the tables, row-level security, the cursor triggers and the private `receipts` storage bucket.
3. Copy `supabase.example.json` to `supabase.json` (it's gitignored) and fill in the project URL and the anon/publishable key.
4. Run with `flutter run --dart-define-from-file=supabase.json`, and pass the same flag to `flutter build`.
5. Go to **Settings → Cloud sync**, create an account and sign in on each device.

How sync works:
- Every row carries `updated_at` and a soft-delete `deleted_at`.
- Each round pushes local dirty rows, then pulls server changes since a per-table cursor (`server_updated_at`, stamped by the server).
- Conflicts resolve last-write-wins.
- Seeded categories and recurring occurrences have deterministic ids, so two devices converge instead of creating duplicates.

## iPhone (build on the Mac)

```sh
flutter build ios --release --dart-define-from-file=supabase.json
open ios/Runner.xcworkspace     # set your Team under Signing, then Run on the device
```

The `juno://` URL scheme is already registered in `ios/Runner/Info.plist`.

## Layout

```
lib/
  app/            router, adaptive shell (pill nav on phones, rail on desktop)
  core/ui/        design system: tokens, type, J* components
  core/db/        drift tables, Ledger (all reads and writes), seed, demo
  core/sync/      Supabase sync engine (SyncCore is testable with a fake remote)
  core/deeplink/  juno://add parsing and handling
  features/       home, activity, add, insights, plan, import, settings
supabase/         server schema
test/             logic + sync tests; screenshots_test renders every screen
```

Before pushing, run `scripts/check.sh`. It runs exactly what CI runs: generated code, formatting, analysis with infos counted as failures, and every test. To have it run automatically on each push, enable the hook once per clone with `git config core.hooksPath .githooks`.

Visual check: `flutter test test/screenshots_test.dart --update-goldens --run-skipped` writes PNGs of every screen at phone and desktop sizes, light and dark, to `test/goldens/`.

## Design

The look combines three earlier projects:
- **Bikey:** an instrument-style frame. Structure comes from 1px hairlines rather than fills, a short accent tick sits above caps labels, the floating pill nav shows a label only on the active tab, and every figure is set in mono.
- **Lazpress:** the type system. Manrope for words, one Instrument Serif italic word per heading, and JetBrains Mono for data. Anything you can press is a pill.
- **Tayseer:** the warm dark palette, burgundy on near-black with cream ink.

Chart colours are a categorical palette validated for colour-blind separation against both surfaces.
