# AutoMailer

A World of Warcraft addon that adds a **Send Mail** button to the mailbox and automatically mails items (and optionally gold) out of your bags to whoever you configure — no manual dragging and dropping required.

## Features

- **One-click sending** — opens the mailbox, click "Send Mail", and AutoMailer attaches and sends everything that matches your rules. Run it as many times as you like; it just picks up whatever's left in your bags.
- **Per-item recipient rules** — a table of rules, one row per item, each with the item's icon, its name, and its own recipient. A blank recipient falls back to your default Recipient. Build it by shift-clicking or dragging items straight out of your bags.
- **Auto-mail crafting reagents** — optionally sends everything sitting in your Reagent Bag.
- **Auto-mail BoE items** — optionally mails Bind-on-Equip items to a separate BoE Recipient, with optional filters for item level (only below your character's level) and rarity (uncommon/rare/epic).
- **Excess gold mailing** — optionally mails gold above a configurable threshold to your Recipient, automatically accounting for mail postage so your balance lands exactly on the threshold. Since gold is the one part of a run that's genuinely awkward to undo, a run that would send gold asks for confirmation first by default (item-only runs still send in one click).
- **Batching** — attaches up to 12 items per letter and automatically continues through every batch and recipient until everything's sent.
- **Shortcuts**:
  - Shift-click a bag item while the options panel is open to add it to your list.
  - Drag a bag item onto the list to add it, or onto an existing row's icon to change what that row matches.
  - Optionally, shift-click while the mailbox is open to auto-start a send run (off by default — see Configuration).
- **Global profile** — optionally share one set of rules across all of your characters instead of configuring each one separately.
- **Debug logging** — toggle verbose logging via `/am debug` or the options checkbox to troubleshoot what the addon is doing.

## Usage

1. Open the mailbox at any mailbox NPC.
2. Click the **Send Mail** button that appears at the top of the mail frame.
3. AutoMailer switches to the Send Mail tab and works through your bags, mailing matching items (and excess gold, if enabled) in batches until it's done.

## Slash Commands

| Command | Description |
|---|---|
| `/am` or `/automailer` | Opens the AutoMailer options panel and your bags. |
| `/am list` | Recaps everything mailed so far this session, grouped by recipient. |
| `/am debug` | Toggles debug logging on/off. |

## Configuration

Open the options panel with `/am` (or via the standard WoW AddOns options menu). It's split across two pages: **AutoMailer** (Recipient and the item table) and **Filters & Automation**, a subcategory underneath it, for everything else below.

- **Recipient** — the default recipient for matched items.
- **Items to AutoMail** — the table of per-item rules. Each row has the item's icon, its name, and a recipient; leave a row's recipient blank to use the default Recipient (shown greyed in the field). Add rows by shift-clicking or dragging an item from your bags, or with **Add Item** to type a name by hand. The red X removes a row.

  Rules added by clicking or dragging an item match that exact item, so a rule for Linen Cloth won't also sweep up Linen Cloth Bandages. Rules you type by hand match loosely — any item whose name contains what you typed — so `Ore` still catches every ore. A question-mark icon marks a loose rule; typing over a row's name converts it to one.
- **Use one global profile for all characters** — shares the recipient, item list, BoE settings, and gold settings across every character instead of keeping them per-character.
- **Automatically send BoEs** — mails any Bind-on-Equip item found in your bags.
  - **Only BoEs with required level lower than yours** — skips BoEs whose required level is at or above your current level.
  - **BoE Recipient** — separate recipient for auto-mailed BoEs (falls back to the default Recipient if left blank).
  - **Limit rarity** — only auto-mail BoEs at or below a chosen rarity (Uncommon, Rare, or Epic).
- **Send all Crafting Reagents** — mails everything in your Reagent Bag.
- **Send gold above threshold to Recipient** — mails gold in excess of the configured threshold, netting out mail postage so your remaining balance matches the threshold exactly.
  - **Ask before sending gold** — shows a confirmation (item/mail counts, recipients, approximate gold amount) before a run that includes a gold mail. On by default.
- **Shift-clicking a mailbox starts a send run** — the shift-click-to-auto-send shortcut. Off by default, since shift is a heavily-used modifier and this can kick off mailing gold before you've looked at anything.
- **Enable debug logging** — same as `/am debug`.
- **Display login message** — toggles the "AutoMailer loaded" chat message on login/reload.

## Notes

- Soulbound items are never mailed.
- A mail send run stops automatically if the mailbox is closed or a mail fails to send.
- One letter can carry at most 12 attachments, so larger sends are automatically split into multiple mails.

## Installation

Place the `AutoMailer` folder in your `World of Warcraft\_retail_\Interface\AddOns` directory, then enable it at the character select screen's AddOns list.

## Development

The addon is split into a few files along what each one is responsible for:

| File | Responsibility |
|---|---|
| `Core.lua` | Chat output and thin wrappers over the container/item APIs. |
| `Profile.lua` | Saved variables, profile switching, and the per-item mail rules. No WoW UI dependencies. |
| `MailQueue.lua` | Scans your bags and turns them into a list of send batches. No WoW UI dependencies. |
| `Send.lua` | The send state machine: works through a built queue one mail at a time. |
| `OptionsPanel.lua` | The options UI. |
| `AutoMailer.lua` | Event registration and slash commands — the entry point. |
| `AutoMailerTemplates.xml` | The item-table row template. |

`Profile.lua` and `MailQueue.lua` have no WoW UI dependencies, so `tests/` exercises them directly under a plain Lua interpreter (no game client needed):

```
lua tests/run_tests.lua
```

`.luacheckrc` lints the addon files themselves against the WoW API surface; run it from the repo root with `luacheck .`.

## Credits

Originally created by RainForDays. See [ATTRIBUTION.md](ATTRIBUTION.md) for full credits and contributor history.

## License

AutoMailer is licensed under the **GNU General Public License version 3** (`GPL-3.0-only`), matching the license declared on the original addon's [CurseForge page](https://www.curseforge.com/wow/addons/automailer). The full license text is in [LICENSE](LICENSE).

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
