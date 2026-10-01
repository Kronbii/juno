# iOS home-screen widget: one-time Xcode setup

The widget code is ready in `ios/JunoWidget/JunoWidget.swift`, and the Flutter side already pushes data (`lib/core/widget/home_widget_sync.dart`). Adding a widget *target* means editing the Xcode project, which has to be done in Xcode. It takes about five minutes on the Mac:

1. Open the workspace with `open ios/Runner.xcworkspace`.
2. Go to **File → New → Target… → Widget Extension**, then:
   - Product name: `JunoWidget`
   - Untick *Include Live Activity* and *Include Configuration App Intent*
   - Choose **Activate** when Xcode asks
3. Xcode creates a `JunoWidget` group with its own `JunoWidget.swift`. **Delete the generated Swift files** (move them to Trash). Then drag `ios/JunoWidget/JunoWidget.swift` from this repo into the group, ticking only the **JunoWidget** target.
4. Select the **Runner** target, open **Signing & Capabilities**, click **+ Capability → App Groups**, and add `group.com.kronbii.juno`.
5. Do the same for the **JunoWidget** target, with the same group.
6. In the JunoWidget target's **General** tab, set the minimum deployment to **iOS 17**, since the widget uses `containerBackground`.
7. Run on the phone, then long-press the home screen and choose **+ → Juno**.

The widget comes in small and medium sizes:
- Both show this month's spending, your daily pace, and a bar for the budget closest to its limit.
- Medium adds the personal/household split and a **New entry** button.

Tapping either size opens `juno://add`, the same quick-add sheet as Back Tap. The widget refreshes whenever you change something in Juno.
