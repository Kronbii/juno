# iPhone setup on the Mac (one time, about 10 minutes)

Everything in Dart is ready. These steps wire up the native pieces that only Xcode can add: the shared App Group, the App Intents, and the widget extension.

## 0. Build once

```sh
flutter pub get
cd ios && pod install && cd ..   # if Flutter generated a Podfile: set `platform :ios, '17.0'` at the top first
open ios/Runner.xcworkspace
```

The Runner target already requires iOS 17. App Intents and interactive widgets need it.

## 1. App Group (lets the app, Siri and the widget share data)
1. Select the **Runner** target, open **Signing & Capabilities**, click **+ Capability**, choose **App Groups**, and add `group.com.kronbii.juno`.
2. You'll repeat this for the widget target in step 3.

## 2. App Intents (log without opening Juno)
`ios/Shared/JunoIntents.swift` is already part of the Runner target, so every build has them:
- **Shortcuts app:** **Log purchase** (asks how much, what it was and who for; Juno files the category), **Log expense** and **Log by sentence**, under Juno.
- **Siri:** "Log a purchase in Juno", "Log a Groceries expense in Juno", "Tell Juno what I spent".
- **Action Button:** Settings → Action Button → Shortcut → choose Juno's **Log purchase**.

They run inside Juno's own process, so they need no App Group when Juno is signed with xtool (which renames groups); the App Group in step 1 is only for the widget extension.

## 3. Widget extension
1. Go to **File → New → Target… → Widget Extension**, then:
   - Product name: `JunoWidget`
   - Untick *Include Live Activity* and *Include Configuration App Intent*
   - Choose **Activate** when Xcode asks
2. Delete the Swift files Xcode generated for it.
3. Drag in `ios/JunoWidget/JunoWidget.swift`, with only the **JunoWidget** target ticked.
4. Add `ios/Shared/JunoIntents.swift` to this target too (File Inspector → Target Membership); it is already in Runner.
5. Under **Signing & Capabilities** for the JunoWidget target, click **+ App Groups** and add `group.com.kronbii.juno`.
6. Set its minimum deployment to **iOS 17**.

You get:
- **Home Screen widgets:**
  - Small: spent this month, safe to spend, budget bar.
  - Medium: adds the personal/household split, **two one-tap buttons** for your most frequent expenses, and **New entry**.
- **Lock Screen widgets:** circular (budget gauge), rectangular and inline.
- **Control Center** (iOS 18): the **Juno: new entry** control.

## 4. Back Tap, the headless way
In the Shortcuts app, create a shortcut with a single action, Juno's **Log purchase**. Then attach it in **Settings → Accessibility → Touch → Back Tap → Double Tap**.

Double-tapping the back of the phone now asks how much, what it was and who it was for, and logs the entry *without opening Juno*. The `juno://add` link recipe (docs/back-tap-shortcut.md) still works if you prefer it.

## How it fits together
The intents write each entry to a small inbox in the App Group. Juno imports it the next time it opens or resumes, using the same matching as `juno://add`. Each entry keeps the intent's id, so nothing is imported twice, and sync then sends it to your other devices.
