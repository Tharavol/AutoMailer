# AutoMailer

A World of Warcraft addon that adds a **Send Mail** button to the mailbox and automatically mails items (and optionally gold) out of your bags to whoever you configure — no manual dragging and dropping required.

## Features

- **One-click sending** — opens the mailbox, click "Send Mail", and AutoMailer attaches and sends everything that matches your rules. Run it as many times as you like; it just picks up whatever's left in your bags.
- **Per-item recipient rules** — configure a list of `Item Name = Recipient` lines. A blank recipient falls back to your default Recipient.
- **Auto-mail crafting reagents** — optionally sends everything sitting in your Reagent Bag.
- **Auto-mail BoE items** — optionally mails Bind-on-Equip items to a separate BoE Recipient, with optional filters for item level (only below your character's level) and rarity (uncommon/rare/epic).
- **Excess gold mailing** — optionally mails gold above a configurable threshold to your Recipient, automatically accounting for mail postage so your balance lands exactly on the threshold.
- **Batching** — attaches up to 12 items per letter and automatically continues through every batch and recipient until everything's sent.
- **Shortcuts**:
  - Shift-click while the mailbox is open to auto-start a send run.
  - Shift-click a bag item while the item-list box has focus to add it to your list.
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

Open the options panel with `/am` (or via the standard WoW AddOns options menu) to configure:

- **Recipient** — the default recipient for matched items.
- **Items to AutoMail** — one entry per line, formatted as `Item Name = Recipient`. Leave the recipient blank to use the default Recipient. While this box has focus, shift-clicking an item in your bags adds it automatically.
- **Use one global profile for all characters** — shares the recipient, item list, BoE settings, and gold settings across every character instead of keeping them per-character.
- **Automatically send BoEs** — mails any Bind-on-Equip item found in your bags.
  - **Only BoEs with required level lower than yours** — skips BoEs whose required level is at or above your current level.
  - **BoE Recipient** — separate recipient for auto-mailed BoEs (falls back to the default Recipient if left blank).
  - **Limit rarity** — only auto-mail BoEs at or below a chosen rarity (Uncommon, Rare, or Epic).
- **Send all Crafting Reagents** — mails everything in your Reagent Bag.
- **Send gold above threshold to Recipient** — mails gold in excess of the configured threshold, netting out mail postage so your remaining balance matches the threshold exactly.
- **Enable debug logging** — same as `/am debug`.
- **Display login message** — toggles the "AutoMailer loaded" chat message on login/reload.

## Notes

- Soulbound items are never mailed.
- A mail send run stops automatically if the mailbox is closed or a mail fails to send.
- One letter can carry at most 12 attachments, so larger sends are automatically split into multiple mails.

## Installation

Place the `AutoMailer` folder in your `World of Warcraft\_retail_\Interface\AddOns` directory, then enable it at the character select screen's AddOns list.

## Credits

Originally created by RainForDays. See [ATTRIBUTION.md](ATTRIBUTION.md) for full credits and contributor history.
