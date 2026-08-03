# Changelog

All notable changes to AutoMailer are documented in this file.

## [5.2] - 2026-08-03

### Fixed
- **Rules are now applied to the Reagent Bag whether or not "Send all Crafting Reagents" is on** ([#28](https://github.com/Tharavol/AutoMailer/issues/28)). That bag was only scanned when the option was enabled, so an explicit rule naming an item the game files in there never matched — and retail auto-sorts cloth, ore and herbs into it, so this hit exactly the items people most want rules for. It failed silently, too: a bag that is never scanned produces nothing to log. The option now controls only whether *unmatched* contents get swept up, which is what it reads as. Bind-on-Equip handling still doesn't apply to that bag.
- **An exact item rule now always beats a name rule that also matches** ([#9](https://github.com/Tharavol/AutoMailer/issues/9)). Rules were checked in storage order, so precedence depended on the order they happened to be added: a `Cloth` name rule added before an exact Linen Cloth rule won, and deleting and re-adding either one silently flipped where Linen Cloth went. Nothing showed that ordering or let you change it, since the two kinds live in separate tables. Specific now beats general, which is what the two-table layout already implies.
- **A send run can start when no default Recipient is set but your rules name their own** ([#23](https://github.com/Tharavol/AutoMailer/issues/23)). The check that a profile was configured predated per-rule recipients and looked only at the Recipient and BoE Recipient boxes, so a perfectly valid rules-only setup was refused before the queue was ever built. Gold has no per-rule equivalent, so a run in that state now says the excess gold wasn't sent instead of dropping it silently.
- **A send run can no longer wedge if the server never answers** ([#10](https://github.com/Tharavol/AutoMailer/issues/10)). Each mail waited on `MAIL_SUCCESS` or `MAIL_FAILED` with no timeout; if neither arrived, the run stayed "in progress" forever and every later click on the Send Mail button said so, until you closed the mailbox. A 20-second backstop now ends the run and says why. It's deliberately generous — it exists to catch a stuck run, not to time out a slow one.
- The item list from `/am list` now reads `Linen Cloth x1` rather than `Linen Clothx1` ([#29](https://github.com/Tharavol/AutoMailer/issues/29)).

### Added
- **Every displayed string now goes through a translation table** ([#22](https://github.com/Tharavol/AutoMailer/issues/22)), in a new `Locale.lua` that loads first. The key is the English text, so there's no English table to keep in sync and an untranslated string shows readable English rather than a blank or an error. Interpolated sentences were converted from concatenation to format strings so word order can be translated too. Adding a language is now a single file calling `A:RegisterLocale`; only the table matching the running client is applied. Debug output is deliberately left untranslated, so it reads the same in any bug report.
- **Tab moves between a rule's name and recipient fields**, shift-tab back ([#25](https://github.com/Tharavol/AutoMailer/issues/25)). Adding a name rule no longer means reaching for the mouse between the two boxes. Focus follows the rule even when committing the name converts it to an item rule and moves it to the other table.
- **The login message now includes the version** ([#24](https://github.com/Tharavol/AutoMailer/issues/24)).
- **Debug logging now accounts for every item a run passed over**, grouped by reason with a sample of the items involved, plus each batch's recipient, subject and contents ([#27](https://github.com/Tharavol/AutoMailer/issues/27)). A run that queued nothing previously reported a single line and no reason — the situation where the log matters most and said least. Reasons are listed in a stable order so two runs over the same bags can be compared, and none of it is collected when debug logging is off.

### Internal
- The Reagent Bag's two differences from an ordinary bag — whether items need to match a rule, and whether BoE handling applies — are now separate flags. They had been one flag, which also conflated them with a third thing: whether the bag was scanned at all. That conflation was [#28](https://github.com/Tharavol/AutoMailer/issues/28).
- `A:GetAutoMailEntry` matches in two passes rather than one, and `A:HasRuleRecipient` answers whether any rule carries its own recipient.
- **The send state machine has its first tests** (`tests/test_send.lua`), covering the watchdog by faking `C_Timer` so stale-timer cases are assertions rather than twenty-second waits. The rest of `Send.lua` still reaches for the mail-form globals directly and can't be driven offline yet ([#15](https://github.com/Tharavol/AutoMailer/issues/15)).
- The suite is up from 36 tests to 69.

## [5.1] - 2026-08-02

### Changed
- **The rule table is now two tables: "Items to AutoMail" and "Name Matches"** ([#2](https://github.com/Tharavol/AutoMailer/issues/2)). Previously both kinds of rule shared one list and were told apart by a question-mark icon standing in for the missing item icon, which read as a missing icon rather than as a distinction. They're now separate tables: rules that identify one item show that item's icon and match it exactly, and rules that match by text sit in their own table with no icon column, since the text names no particular item.
- **Typing a name the client recognizes as an item now makes the rule an exact item rule** and moves it into the Items table, icon and all. Anything else stays a name rule in Name Matches. This narrows the rule — `Linen Cloth` typed in full stops matching Linen Cloth Bandages — so add rules under Name Matches when loose matching is what you want. Stored rules, including every rule migrated from a pre-4.9 text list, are never converted on load: an upgrade still can't change what gets mailed.
- **Add Item** now only adds the item on your cursor; the button for typing a rule by hand is **Add Name Rule**, under the Name Matches table.
- Both tables read from the same saved rule list, so saved variables are unchanged and no migration is involved.

### Fixed
- **Name rules no longer match items whose names they merely contain** ([#4](https://github.com/Tharavol/AutoMailer/issues/4)). Matching ran in both directions, so a rule for `Heavy Silken Thread` also mailed Silken Thread — and, with no minimum length, an item named `Thread` too. Only the intended direction remains: your text has to appear in the item's name. This can only ever mail *fewer* things than before, but it is a behavior change if a setup was leaning on the over-match.
- **An item the client hasn't cached yet no longer silently disables BoE handling for it** ([#5](https://github.com/Tharavol/AutoMailer/issues/5)). `GetItemInfo` returns nothing for an uncached item, which left `bindType` nil, quietly failed the BoE check, and let a run under-send while reporting success. The skip is now logged and the item's data is requested so the next run classifies it. itemID rules were always unaffected, which is what made this hard to notice.
- **The version no longer displays with a doubled `v`** (`vv5.0.2`) in the options panel and the send-run chat line ([#3](https://github.com/Tharavol/AutoMailer/issues/3)). The TOC version has carried its own leading `v` since 5.0.2; both call sites were still adding another.
- The `MAIL_SHOW` handler no longer retries forever when `MailFrame` never appears; it gives up after 20 frames and logs it.

### Internal
- **`GetMoney`, `GetSendMailPrice` and `UnitLevel` now go through `Core.lua`** like the container and item APIs already did, and the excess-gold arithmetic is split out of `SendMailBatch` into `A:HasExcessGold` / `A:ExcessGoldToSend`. That math is the only irreversible part of a send run and the source of the 4.7/4.8 postage bugs and the 5.x shortfall, and it had no test coverage; it now has tests for the threshold boundary, postage exceeding the excess, and the clamp at zero.
- **The promote/demote decision moved out of the options panel into `A:ApplyRuleName`** in `Profile.lua`, which takes the name resolver as an argument. The panel now only renders the outcome, and the policy is testable without a frame.
- The ordinary-bag and Reagent-Bag scans in `BuildMailQueue` are one function taking a flag instead of two near-copies that had already drifted apart.

## [5.0.2] - 2026-08-01

Packaging and tooling only — no functional changes.

### Changed
- **Releases are now built by [BigWigsMods/packager](https://github.com/BigWigsMods/packager).** The zip now contains only what the addon needs; development files (`.github/`, `.luacheckrc`, `.pkgmeta`, `tests/`) no longer ship.
- **The version in the TOC now comes from the release tag** rather than being maintained by hand, so it can no longer disagree with the release it was published under. Versions now carry a leading `v`.
- Added GitHub Actions running luacheck and the test suite on every push and pull request.
- Wrapped two long lines in `Send.lua` and `OptionsPanel.lua` to satisfy the line-length limit. The displayed strings are unchanged.

## [5.0.1] - 2026-07-26

### Changed
- **"Ask before sending gold" is now off by default.** A run that includes gold sends immediately instead of showing the confirmation popup added in 5.0. The checkbox on the Filters & Automation page still exists for anyone who wants the prompt back.

## [5.0] - 2026-07-26

### Changed
- **Split `AutoMailer.lua` into `Core.lua`, `Profile.lua`, `MailQueue.lua`, and `Send.lua`.** One ~800-line file carrying saved-variable management, the bag scan, and the send state machine is now four files along the seams that already existed: shared utilities/API wrappers, profile/rule storage, queue building, and the mail-send state machine. `AutoMailer.lua` is now just event registration and slash commands. No behavior change; load order is explicit in the TOC.
- **The soulbound check no longer scans tooltip text.** `A:ItemIsSoulbound` built a hidden `GameTooltip` and string-matched `ITEM_SOULBOUND` against its first four lines, for every occupied bag slot, on every send run - slow, and only correct if the soulbound line happened to land in those first four. Replaced with `C_Item.IsBound`, which answers the same question directly. Warband-bound-until-equipped gear is still treated as mailable, matching the old check's behavior.
- **Shift-clicking a mailbox open no longer auto-starts a send run by default.** That included mailing gold, before you'd seen anything, off a modifier key that's heavily used for other things. It's now a checkbox on the new "Filters & Automation" page (off by default); the existing shortcut for adding an item to your list (shift-click while the options panel is open) is unaffected.
- **A run that would send gold now asks for confirmation first**, showing the item/mail counts, recipients, and an approximate gold amount (the exact figure is only known at send time - see the 4.7/4.8 postage notes). Toggle via "Ask before sending gold" on the Filters & Automation page; on by default. Item-only runs are unaffected and still send in one click.
- **The options panel is now two pages.** "AutoMailer" has just the Recipient field and the item table; BoE, reagent, gold, and general settings (debug logging, login message, the new auto-send and gold-confirmation toggles) moved to a "Filters & Automation" subcategory underneath it, so the crowded single page (already tight before the item table) has room.
- Options panel widgets no longer create globally-named frames (`recipientBox`, `boeRecipientBox`, and the various `AM*CB` checkboxes previously did). Those names were generic enough that another addon creating the same name could collide with them - whichever loaded second silently won. Every widget the panel creates is unnamed now, except the rarity dropdown, which `UIDropDownMenuTemplate` requires to resolve its own sub-frames through `_G`.

### Added
- **A Lua test suite for the non-UI logic** (`tests/`), runnable outside the game with a plain Lua interpreter (`lua tests/run_tests.lua`). Covers the legacy-string-to-table migration, rule sanitization, exact-vs-loose item matching, and `BuildMailQueue`'s batching, soulbound/locked/self-recipient skipping, BoE rarity filtering, reagent-bag handling, and excess-gold queuing - the exact area responsible for most of this addon's past regressions (see the 4.4 through 4.8 entries below).
- **A `LICENSE` file and per-file license notices.** The original AutoMailer is published on CurseForge under GPL-3.0-only; this fork now states that explicitly instead of shipping unlicensed. See `ATTRIBUTION.md` for the full note.

### Fixed
- `SendMailBatch`'s item-attachment step now re-checks that a bag slot still holds the item that was queued before picking it up. A queue built before a confirmation dialog (or before earlier mails in the same run move items around) could otherwise pick up and mail whatever now happens to occupy that slot.

## [4.9] - 2026-07-26

### Changed
- **"Items to AutoMail" is now a table instead of a free-text box.** The multiline `Item Name = Recipient` edit box has been replaced with a proper ScrollBox-backed list: one row per rule, showing the item's icon (with its tooltip on hover), its name in quality color, its own recipient field, and a delete button. Rows whose recipient is blank show the default Recipient greyed out in the field, so the fallback is visible instead of having to be remembered.
- **Rules are stored as structured data.** `A.db.items` moved from one newline-delimited string to a list of `{ itemID, itemName, recipient }` records. Existing text lists are migrated automatically on first load; the migration is one-way, so a profile saved by 4.9 won't be readable by 4.8 and earlier.
- **Shift-clicking a bag item no longer requires the item box to have focus** — it adds a row whenever the options panel is open.

### Added
- Items can be dragged from your bags onto the list to add them, or dropped onto an existing row's icon to change what that row matches. **Add Item** adds a blank row for typing a name by hand.
- Rules added by clicking or dragging an item now match that exact item by itemID, so a rule for Linen Cloth no longer also sweeps up Linen Cloth Bandages. Rules typed by hand (and every rule migrated from a pre-4.9 text list) keep the original loose substring matching, so `Ore` still catches every ore and existing setups behave exactly as they did before. Typing over a row's name converts it back to a loose name rule, which the question-mark icon indicates.

### Fixed
- The per-character and global profiles could have been handed the same `items` table when both were created from defaults in the same session, leaving them sharing one rule list. Each profile now gets its own defaults.
- **The repository shipped no license file.** The original addon is published on CurseForge under the GNU General Public License version 3, but this fork never carried that forward, leaving the terms unstated. Added the full `LICENSE` text, per-file notices, and an `X-License` TOC field, all as `GPL-3.0-only` to match what upstream declared.

## [4.8] - 2026-07-23

### Added
- The addon version now shows next to the title on the options panel and in the "Starting AutoMailer send run" chat message.

### Fixed
- **Excess-gold threshold still landing short intermittently, by whatever postage the previous mail charged.** `ProcessMailQueue` advanced to the next batch a fixed 0.3s after `MAIL_SUCCESS`, assuming that was long enough for `GetMoney()` to reflect the mail that had just sent - but that lag varies with latency, so a slow update meant the next batch's excess-gold math (`SendMailBatch`) read a stale, too-high `GetMoney()` that hadn't yet subtracted the prior mail's postage, silently short-changing the final balance by exactly that amount. Fixed by polling `GetMoney()` after `MAIL_SUCCESS` until it actually changes (capped at 2s) before advancing, instead of guessing a fixed delay.

## [4.7] - 2026-07-21

### Fixed
- **Send Mail button sometimes missing on the mailbox's first open of a session.** `MAIL_SHOW` can reach addons before Blizzard's own `Blizzard_MailFrame` module finishes loading, so `MailFrame` didn't exist yet and `EnsureMailTriggerButton` silently did nothing for that open - every later open worked because the module was already loaded by then. Fixed by retrying on the next frame when `MailFrame` isn't ready yet instead of giving up.
- **Excess-gold threshold landing short by one mail's postage.** `GetSendMailPrice()` was queried immediately after `ClearSendMail()`, while the compose form still had no recipient on it, and under-reports postage on a form that blank - the real send afterward (with the recipient filled in) then charged the true, higher fee, leaving the balance short. Fixed by setting the recipient on the form before querying the postage, so the reading matches what the mail actually costs once it sends.

## [4.6] - 2026-07-20

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
