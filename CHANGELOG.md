# Changelog

All notable changes to AutoMailer are documented in this file.

## [Unreleased]

### Fixed
- **Bag/item lookups could throw on current retail.** `A:GetContainerNumSlots`, `A:GetItemInfo`, and the pickup step in `A:AttachItemToMail` fell back to the legacy global container/item API (`GetContainerNumSlots`, `GetItemInfo`, `PickupContainerItem`) whenever the `C_Container`/`C_Item` call didn't return a result — most commonly `GetItemInfo` on an item that isn't cached yet, a routine case, not an edge case. Those globals no longer exist on current retail, so the fallback could error with `attempt to call a nil value` instead of just returning nothing. Removed the dead fallback and call `C_Container`/`C_Item` directly.

## [4.5] - 2026-07-20

### Changed
- Rules that resolve to the currently logged-in character as the recipient (default Recipient, per-item rule, BoE Recipient, or gold recipient) are now skipped instead of queuing a pointless self-mail. Useful when a shared/global profile's default recipient happens to be whichever alt you're currently playing.

## [4.4] - 2026-07-19

### Fixed
- **Send Mail button disappearing after a completed run.** `ResetMailSendState()` was unconditionally hiding the mail trigger button on every finished run, not just when the mail frame closed. The button now survives a normal completed run and stays clickable; it's still hidden correctly via the separate `MAIL_CLOSED` handler.
- **Gold not actually being sent.** `MoneyInputFrame_SetCopper(SendMailMoney, money)` only updates the money editbox's displayed text — it doesn't stage the amount for `SendMail()`. Fixed by calling `SetSendMailMoney(money)` directly before sending, alongside the (now cosmetic) `MoneyInputFrame_SetCopper` call.
- **Debug/print log lines silently dropping every argument after the first.** `A:Print`/`A:Log` built output with `"prefix" .. tostringall(...)`, and string concatenation isn't a multi-result context in Lua, so only `tostringall`'s first return value survived. Fixed by joining with `strjoin(" ", tostringall(...))`, which keeps every argument.
- **Excess-gold threshold landing slightly below target.** Mail postage (`GetSendMailPrice()`) is deducted from `GetMoney()` independent of any attached money, but the threshold math didn't account for it, leaving the sender's balance short by the postage amount. Fixed by subtracting postage from the excess amount before queuing the gold mail.
- **Postage miscalculated when a run sent both items and gold.** Postage isn't a flat per-mail fee — it scales with however many items are currently attached to the send-mail form, so a single upfront `GetSendMailPrice()` reading could never account for a multi-item batch's real cost. Fixed by no longer predicting postage upfront at all: the gold batch is queued as a placeholder, and `SendMailBatch` resolves the real amount immediately before that specific mail sends, reading live `GetMoney()` (which by then reflects every prior mail's actual postage) and subtracting the threshold plus a freshly-queried, guaranteed-0-item postage rate for this mail.
- **"Send all Crafting Reagents" not sending anything.** The bag-scanning loop only covered `NUM_BAG_SLOTS` (backpack + 4 regular bags) and never reached bag 5, the Reagent Bag, where crafting materials actually auto-sort to. Rather than trying to classify "is this a reagent" via item metadata (which proved unreliable — `GetItemInfo` fields can be uncached, and classID/type schemes shift between expansions), the option now simply mails anything non-soulbound sitting in the Reagent Bag, still honoring a specific recipient override from the item list if one matches.

## [4.3] - 2026-07-19

Purely additive session: new user-facing options on top of an already-working mail-send flow, plus one correctness fix caught before it shipped.

### Added
- **Debug logging checkbox** in the options panel, bound to the same `AutoMailer.debugLogging` variable already toggled by `/am debug`.
- **Global profile option** ("Use one global profile for all characters"). Introduced a new `AutoMailerGlobal` saved-variables table, split settings into a "profile" set (items, recipients, BoE/reagent/gold settings) that mirrors into either the per-character or global table, and a "meta" set (login message, debug logging, the toggle itself) that always stays per-character. `A:RefreshActiveProfile()` points `A.db` at whichever table is active, and toggling the checkbox re-syncs every control in the panel immediately.
- **Excess-gold mailing option** ("Send gold above threshold to Recipient" + a numeric Gold Threshold input, default 50000g). When enabled, a gold-only batch is appended to the mail queue whenever `GetMoney()` exceeds the threshold.
- Added "Claude" to the addon's `## Author:` line in the TOC.

### Fixed
- Initial gold-sending attempt assumed `SendMail()` took a 4th "money" argument — it doesn't. Money, like item attachment, must be staged client-side first; fixed by calling `MoneyInputFrame_SetCopper(SendMailMoney, money)` before `SendMail()`. (This call was later found to be insufficient on its own — see the 4.4 gold-sending fix above.)

## Earlier — retail compatibility restoration

Work to bring the addon back to a working baseline on current WoW retail clients, prior to the versioned sessions above.

### Fixed
- Addon failed to load cleanly due to an outdated Interface version in the TOC; updated to the current retail-compatible value.
- Options panel had runtime errors from outdated registration and UI assumptions; switched to a compatibility-safe registration path.
- The old mail-attachment flow (relying on invented/outdated APIs) failed to reliably attach items in the current client; reworked into an explicit state-based send flow using the real pickup/click attachment path.
- The "Send Mail" button initially overlapped the mail UI and didn't hide correctly; added proper frame layering and hooked it to the mail frame's hide event.

### Added
- Per-item recipient rules in the options box (`Item Name = Recipient` format, blank recipient falls back to the default Recipient).
