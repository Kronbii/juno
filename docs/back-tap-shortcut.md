# Back Tap → log an expense

Double-tap the back of your iPhone, enter an amount, say what it was, pick who it was for (Personal, Household or Other), and Juno files it in the right category and shows a toast with an **Undo** button. It works offline, and the entry syncs later if sync is on.

## The native way: Log purchase (recommended)

Juno adds a **Log purchase** action to the Shortcuts app. It runs without opening Juno, so there's no Face ID and no switching apps.

1. In **Shortcuts**, tap **+**, search **Juno**, and tap **Log purchase**. Rename the shortcut **Log purchase** and tap **Done**. There's nothing to configure: it always asks.
2. Go to **Settings → Accessibility → Touch → Back Tap → Double Tap** and choose **Log purchase**.
3. Double-tap the back of the phone. It asks **How much?**, **What was it?** and **Who for?** (Personal, Household or Other), then confirms what it logged.

The entry is kept on the phone and imported the next time you open Juno, which picks its category from what you wrote (see *How Juno picks the category* below) and syncs it. Siri works too: "Log a purchase in Juno".

## The link way (opens Juno)

## 1. Build the Shortcut

In the **Shortcuts** app, tap **+** and name the shortcut **Log expense**. Then add these actions in order:

1. **Ask for Input**: set Input Type to *Number* and Prompt to "Amount". Its result is *Provided Input*.
2. **Ask for Input**: set Input Type to *Text* and Prompt to "What was it?". Type or dictate a few words, like "kalei coffee" or "spinneys".
3. **URL Encode**: encode the text from step 2, so spaces and Arabic survive the link. Its result is *URL Encoded Text*.
4. **List**: add three items, `Personal`, `Household` and `Other`.
5. **Choose from List**: choose from the list in step 4. Its result is *Chosen Item*.
6. **URL**: enter the text below, inserting the three variables where the brackets are:
   ```text
   juno://add?amount=[Provided Input]&note=[URL Encoded Text]&scope=[Chosen Item]
   ```
7. **Open URLs**.

### How Juno picks the category

From the note, cheapest first, and only among the categories of the scope you picked (a household entry never lands in a personal category):

1. **Your history:** a note you have filed before goes where it went last time. If you correct an entry's category, the next one follows the correction.
2. **Keywords, on the phone:** common words ("coffee", "fuel", "rent").
3. **The AI, only for new notes:** it gets that scope's categories and your own past entries that share words with the note, and must answer with one of those category names. A guess it isn't sure of shows as "Food & Outings?" in the toast.

If the AI can't be reached (offline, or you left Juno before it answered), the entry is saved uncategorised and filed the next time Juno opens online. Once filed, that note is history, so it never costs another AI call.

## 2. Attach it to Back Tap

Go to **Settings → Accessibility → Touch → Back Tap → Double Tap** and choose **Log expense**. You can attach a different shortcut to **Triple Tap**, for example one that adds `&confirm=1` to the link so it opens the add sheet instead of saving straight away.

## Link reference

| Parameter | Meaning |
|---|---|
| `amount` | `12.50`, `12,50`, `$12.50`. If you include it, the entry saves straight away. |
| `category` | Optional. Matched loosely by name: "grocery" and "Groceris" both find Groceries. A spending category belongs to one scope, and the entry takes that scope. Leave it out to have Juno file the entry from the note. |
| `scope` | `personal`, `household` or `other`. When two scopes each have a category of the name given (Subscriptions), this picks which. Without a category, it is who the entry was for (default personal). |
| `note` | What it was. Without a category, Juno files the entry from this. |
| `account` | Matched by name. If you leave it out, the first account is used. |
| `type` | `expense` or `income`. If you leave it out, the category decides, so "Salary" means income. |
| `date` | `2026-10-01` or `yesterday`. If you leave it out, today is used. |
| `confirm=1` | Opens the add sheet prefilled instead of saving. |

A link with no amount opens the add sheet. You can test links on any platform in **Settings → Back Tap → Try a link**.
