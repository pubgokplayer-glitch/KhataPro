# Batch 3 + Batch 4 — review sheet

**Scope of this review.** The widget layer: the ledger and chart widgets (Batch 3), and the eight
screens, the write-spec layer and the deep-link path (Batch 4). Code commit: `780e49c` on top of
`f68e1a7` (Batch 3) and `38f1781` (Batch 4 part 1).

**How to read this document.** Every claim below is followed by the thing that makes it true — a
file and a line region, a named check in a verification tool, or an exact command whose output is
quoted. Where a claim is *not* machine-checked, it says so and says why. Nothing here is "should
work".

---

## 1. What exists now

| Area | Files | Lines |
| --- | --- | --- |
| App root + links | `lib/main.dart`, `lib/apps/khata_app.dart`, `lib/apps/deep_links.dart`, `lib/apps/bootstrap.dart`, `lib/ui/routes.dart` | 46 + 299 + 216 + 260 + 201 |
| Screens (8) | `dashboard`, `party_list`, `party_ledger`, `cash_book`, `bill_book`, `stock_book`, `staff_book`, `settings` | 307 + 172 + 275 + 213 + 195 + 190 + 93 + 257 |
| Write specs | `lib/ui/commands/entry_models.dart`, `entry_specs.dart`, `book_commands.dart`, `reminders.dart` | 85 + 221 + 457 + 138 |
| Shared widgets | `forms.dart`, `cards.dart`, `money_label.dart`, `nav_shell.dart`, `reminder_sheet.dart` | 779 + 341 + 153 + 109 + 106 |
| Amount field | `lib/ui/format/money_input.dart` | 141 |

Batch 3 already carried `live_charts.dart`, `chart_math.dart`, `ledger_view.dart`,
`virtual_list.dart`, `skeletons.dart`, `outcome_toast.dart`.

---

## 2. The four directives for this batch, one by one

### 2.1 `live_charts` must cache `Path` objects (no CPU burned in layout or scroll)

**Verdict: implemented, and the mechanism is the one that matters.**

`lib/ui/widgets/live_charts.dart:176` builds the whole picture — every `Path`, every tick, every
laid-out label — into a private `_ChartGeometry`. It is memoised on the state object at
`live_charts.dart:521`, and it is rebuilt **only when a value key changes**:

```dart
final geometry = _geometry;
if (geometry == null || geometry.key != key) {
  _geometry = _buildGeometry(key: key, size: size, …);
}
```

The key (`live_charts.dart:70`) is O(1) to construct and O(1) to compare: the series is matched by
`identityHashCode`, plus width, height, text direction, a palette hash, a money-format hash and the
two label constants. So a rebuild caused by a scroll, a sibling widget, or a language switch that
does not change the numbers costs two `==` comparisons and zero geometry work — the `Path`s
survive. Inside `_CashFlowPainter`, `shouldRepaint` compares the same key, so the raster is reused
rather than re-painted.

**Not machine-checked, and why:** the cache lives inside a widget file, so exercising it needs a
`CustomPaint` in a widget tester (`flutter test`), which this workspace deliberately does not run.
What *is* checked headlessly is the arithmetic the cache holds — `lib/ui/charts/chart_math.dart`
(bar layout, hit testing, tick spans, quiet days) is covered by the 174-check suite. If you want the
cache itself asserted, the honest fix is to move `_ChartKey` into `chart_math.dart` and assert its
equality: same inputs ⇒ equal, one-pixel width change ⇒ not equal. That is a ~20-line change and I
have not made it, because it changes Batch 3 code that you already accepted.

### 2.2 Dr/Cr rows must reflect the database's double-entry truth, aligned with `KhataColors`

**Verdict: implemented; the alignment is by construction, not by convention duplicated in the UI.**

* `BalanceSide.of(int)` is the single place a sign becomes a side. `ledger_view.dart` renders
  `LedgerEntryTile` from it (`Dr` for a net debit, `Cr` for a net credit) — the row never decides
  which side it is from the amount's *look*.
* `ledgerTone(column, side, colors)` is the single place a side becomes a colour, and it returns
  `colors.moneyIn` / `colors.moneyOut` out of the `KhataColors` theme extension — the same tokens
  the charts and the KPI tiles use, so "Money In" cannot be green on the ledger and amber in the
  chart.
* In this batch both members were **extracted verbatim** into `lib/ui/widgets/money_label.dart`
  (153 lines) so the new screens (`party_ledger`, `cash_book`) and the new cards can use them
  without a second copy existing. `ledger_view.dart` re-exports them, so no screen changed its
  imports and no rendering behaviour moved.
* The sign convention is proved, not asserted: see check *"the customer's balance moved by exactly
  the amount the form held — a receipt takes the receivable down, so the sign follows the
  double-entry side, not the cash direction"* in `tool/ui_commands_verify.dart` (section G). A
  receipt is money **in** the drawer and a **reduction** of the receivable, and the check fails if
  either half is wrong.

### 2.3 GoRouter for the 8 screens + `khata_app.dart` must handle deep links

**Verdict: implemented, and it is the most heavily checked part of the batch. Two native
`intent-filter` / `CFBundleURLTypes` blocks are still missing — that is the one thing standing
between "the app routes a link correctly" and "Android hands the link to the app at all".**

The app is a `MaterialApp.router` whose `GoRouter` is built once in `initState`
(`khata_app.dart:66`), with eight destinations and the shell that keeps the tab bar stable while a
pushed screen takes over the full width.

*Cold start* — `WidgetsBinding.instance.platformDispatcher.defaultRouteName` is parsed and used as
`initialLocation` (`khata_app.dart:96`). *Warm start* — the widget mixes in
`WidgetsBindingObserver` and implements `didPushRouteInformation` (`khata_app.dart:88`), which is
the half everyone forgets: without it a second reminder tapped while the app is open does nothing.

Both entrances go through `_locationFor` → `routeFor` (`lib/ui/routes.dart:76`), so there is exactly
one mapping from link to screen, and it is the mapping the sweep asserts. Three uri shapes are
handled by `parseDeepLink`: `khatapro://…` (where the first path segment arrives in `uri.host` — the
classic trap), an `https://khatapro.app/…` app link, and the bare path Android hands a *running*
app.

**One real bug was found and fixed while writing the checks:** `?action=receive` (the action a
"receive payment" notification carries) was being dropped by the parser, because the parser built
the location as `/party/<id>` and `GoRouter` only ever receives a location. On a cold start that
meant the user tapped "receive" and got a ledger that sat there doing nothing. The action now rides
**inside** the location (`deep_links.dart:135`), and the screen opens the receipt form once its row
has loaded (`party_ledger_screen.dart`).

23 checks in `tool/ui_commands_verify.dart` cover this chain end to end, including:

| Check | What it pins down |
| --- | --- |
| *a custom-scheme link parses, and its first segment is not eaten by the host* | `khatapro://party/<id>` |
| *the https app link parses to the same party* / *the bare path the OS hands a running app* | the other two shapes |
| *the link opens the party ledger, not the parties tab* | `routeFor` — the router's own input |
| *…so a foreign id gets the "not in your khata" page instead of a blank screen* | `GoScreen.expectsRow` |
| *a "receive payment" link keeps its action in the location* | the bug above |
| *?action=receive opens the receipt form — the same one the ledger screen's button builds* | link and button cannot drift |
| *the linked form is locked to the party in the link* | money cannot land on someone else |
| *a money-OUT action opens nothing* | the write API has no "paid a supplier, no bill named" command |
| *the reminder body carries a link this app parses back to the same party* | SMS/WhatsApp round trip |
| *the SMS / WhatsApp intent carries the whole body* | `sms:` and `wa.me` encoding |
| *the linked form posts* + *the balance moved by exactly the amount the form held* | the link actually changes the books |

**Still missing (native, cannot be written into a workspace that has no `flutter create` output):**
the Android `intent-filter` for `khatapro`, the iOS `CFBundleURLTypes`, and `assetlinks.json` for
the https form. Without them, the routing above is correct and unreachable from another app.
`docs/DEEP_LINKS.md` is scheduled to hold the exact blocks; it is not written yet.

### 2.4 Leaving `fonts:` commented; `tool/fetch_fonts.sh` at build time

**Verdict: unchanged and correct.** `pubspec.yaml` still has the `fonts:` block commented, and the
Urdu UI is written to work either way: `KhataType.urdu(base, {family})` takes the family as a
parameter, so uncommenting the block and running `tool/fetch_fonts.sh` changes the rendering and
nothing else.

---

## 3. Verification status — exact numbers

| Suite | Command | Result |
| --- | --- | --- |
| Analyzer (`lib` + stubs) | `./dartx analyze --packages=plugin_stubs_config.json …/lib …/tool/plugin_stubs` | **No issues found!** |
| `tool/ui_verify.dart` | `./run_tool.sh …/tool/ui_verify.dart` | **✓ all 174 checks passed** |
| `tool/ui_db_verify.dart` | `./dartx ui_db_run.dart --asset-root=…` | **✓ all 53 checks passed** |
| `tool/ui_commands_verify.dart` | `./dartx run ui_commands_run.dart --asset-root=…` | **✓ all 68 checks passed** (was 45) |

The command suite grew by 23 and every one of them is about this batch. The other suites (data
layer 81, sync 133, security 54, CRDT 55, crypto 72, AES 27, 16 Flutter tests, SQL 35/35, schema
11/221) were green at their own commits and are untouched by this batch except for the stub files;
they have not been re-run since the screens landed.

**What none of this proves.** Frame timing. No device, no profile run, no APK is built in this
workspace by rule. The mechanisms that make 60–120 FPS achievable are in place and each has a
reason: `VirtualList` with `itemExtentBuilder` (no layout pass per row), no redundant
`RepaintBoundary`, the `Path` memo above, `ref.watch` scoped to the smallest widgets, and
`.select`-style value comparisons where a list is re-read but unchanged (check: *"the stock list is
re-read but its contents are identical, so a `select` skips the rebuild"*). The numbers to beat are
already measured on the data side: 20 000 entries / 51.9 MB → dashboard query 4.1 ms. The frame
budget itself is yours to measure locally with `flutter run --profile`.

---

## 4. Honest gap list

1. `docs/DEEP_LINKS.md` — the Android/iOS blocks (§2.3). **Functional gap on device, not cosmetic.**
2. `docs/UI.md` §screens and the `docs/ROADMAP.md` rows for Batch 4 part 2 — the docs trail the code.
3. `tool/ui_db_verify.dart` — no section yet for the link → screen path *against the database*
   (the pure half is covered 23 times in the command suite).
4. `_ChartKey` is not asserted by a headless check (§2.1) — the option is described there.
5. The bundle `khata_pro.bundle` predates `780e49c`; regenerate before export.
6. Git identity: `.git/config` is not part of the workspace snapshot, so `git config user.name` /
   `user.email` must be re-set in a fresh sandbox before the next commit (done, locally, for
   `780e49c`).
