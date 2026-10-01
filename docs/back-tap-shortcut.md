# Back Tap → log an expense

Double-tap the back of your iPhone, enter an amount, pick a category and a scope, and Juno logs the entry and shows a toast with an **Undo** button. It works offline, and the entry syncs later if sync is on.

## 1. Build the Shortcut

In the **Shortcuts** app, tap **+** and name the shortcut **Log expense**. Then add these actions in order:

1. **Ask for Input**: set Input Type to *Number* and Prompt to "Amount".
2. **List**: add your category names, one per item. In Juno, **Settings → Back Tap quick add → Copy categories** copies them all, so you can paste them in.
3. **Choose from List**: choose from the list in step 2. Its result is *Chosen Item*.
4. **List**: add two items, `Personal` and `Household`.
5. **Choose from List**: choose from the list in step 4. Its result is *Chosen Item 2*.
6. **URL**: enter the text below, inserting the three variables where the brackets are:
   ```text
   juno://add?amount=[Provided Input]&category=[Chosen Item]&scope=[Chosen Item 2]
   ```
7. **Open URLs**.

## 2. Attach it to Back Tap

Go to **Settings → Accessibility → Touch → Back Tap → Double Tap** and choose **Log expense**. You can attach a different shortcut to **Triple Tap**, for example one that adds `&confirm=1` to the link so it opens the add sheet instead of saving straight away.

## Link reference

| Parameter | Meaning |
|---|---|
| `amount` | `12.50`, `12,50`, `$12.50`. If you include it, the entry saves straight away. |
| `category` | Matched loosely by name: "grocery" and "Groceris" both find Groceries. |
| `scope` | `personal` or `household`. If you leave it out, the category's default scope is used. |
| `note` | Free text. |
| `account` | Matched by name. If you leave it out, the first account is used. |
| `type` | `expense` or `income`. If you leave it out, the category decides, so "Salary" means income. |
| `date` | `2026-10-01` or `yesterday`. If you leave it out, today is used. |
| `confirm=1` | Opens the add sheet prefilled instead of saving. |

A link with no amount opens the add sheet. You can test links on any platform in **Settings → Back Tap quick add → Try a link**.
