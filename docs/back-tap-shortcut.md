# Back Tap → log an expense

Double-tap the back of your iPhone, enter an amount, say what it was, pick who it was for (Personal, Household or Other), and Juno files it in the right category and shows a toast with an **Undo** button. It works offline, and the entry syncs later if sync is on.

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

From the note, cheapest first:

1. **Your history:** a note you have filed before goes where it went last time. If you correct an entry's category, the next one follows the correction.
2. **Keywords, on the phone:** common words ("coffee", "fuel", "rent").
3. **The AI, only for new notes:** it gets your categories (those usual for the scope you picked first) and your own past entries that share words with the note, and must answer with one of your category names. A guess it isn't sure of shows as "Coffee?" in the toast.

If the AI can't be reached (offline, or you left Juno before it answered), the entry is saved uncategorised and filed the next time Juno opens online. Once filed, that note is history, so it never costs another AI call.

## 2. Attach it to Back Tap

Go to **Settings → Accessibility → Touch → Back Tap → Double Tap** and choose **Log expense**. You can attach a different shortcut to **Triple Tap**, for example one that adds `&confirm=1` to the link so it opens the add sheet instead of saving straight away.

## Link reference

| Parameter | Meaning |
|---|---|
| `amount` | `12.50`, `12,50`, `$12.50`. If you include it, the entry saves straight away. |
| `category` | Optional. Matched loosely by name: "grocery" and "Groceris" both find Groceries. Leave it out to have Juno file the entry from the note. |
| `scope` | `personal`, `household` or `other`. If you leave it out, the category's default scope is used. |
| `note` | What it was. Without a category, Juno files the entry from this. |
| `account` | Matched by name. If you leave it out, the first account is used. |
| `type` | `expense` or `income`. If you leave it out, the category decides, so "Salary" means income. |
| `date` | `2026-10-01` or `yesterday`. If you leave it out, today is used. |
| `confirm=1` | Opens the add sheet prefilled instead of saving. |

A link with no amount opens the add sheet. You can test links on any platform in **Settings → Back Tap → Try a link**.
