# Deliverable 4 — the UI layer

Two halves, and they are at very different stages of proof:

| half | where | how it is proven |
| --- | --- | --- |
| **state layer** — what every screen reads, and how it learns that something changed | `lib/ui/format`, `lib/ui/charts`, `lib/ui/lists`, `lib/ui/state`, `lib/ui/theme` | **pure Dart, and verified twice**: `tool/ui_verify.dart` (174 checks, logic) and `tool/ui_db_verify.dart` (53 checks, against a real database with real writes) |
| **widget layer** — `MaterialApp`, the eight screens, the shared widgets | `lib/apps`, `lib/ui/screens`, `lib/ui/widgets` | **not written yet.** Listed in §6 with the file names, so the next session starts with a checklist rather than an archaeology dig |

Both suites run in this workspace with no Flutter SDK, because the state layer does not
import Flutter — it is plain Dart over the database, and that was a deliberate choice, not
an accident. It is also why the widget layer is expected to stay thin: a screen should be
"watch a provider, render an `AsyncValue`, call a command" and hold no arithmetic of its
own.

```
cd /tmp/harness                                   # rebuilt by tool/bootstrap_harness.sh
./dartx run ui_db_run.dart --asset-root=/home/user/khata_pro   # 53 checks, real DB
./run_tool.sh /home/user/khata_pro/tool/ui_verify.dart --asset-root=/home/user/khata_pro
```

---

## 1 · The reactive contract (and the four things it cost to get right)

Drift's `watch()` **cannot** be used in this app, and the reason is worth keeping written
down because it looks like a bug in the app rather than a property of the toolchain:

* the schema is defined in SQL, and `KhataDatabase.allTables` is deliberately empty, so
  `customSelect` over a view builds `MultipleUpdateQuery([])`, whose `matches` is `false`
  for an empty set — the stream emits once and never again;
* `customStatement` is documented by drift not to update stream queries at all, and every
  DAO writes with it.

So the notification is explicit: **`ChangeBus`**, a coalescing broadcast stream, and the
database tells it when a write commits.

### The signal carries a number

`ChangeBus.changes` is `Stream<int>`, not `Stream<void>`, and that is load-bearing: a
`StreamProvider<void>` produces `AsyncData(null)` for ever, Riverpod compares states, and
an emission equal to the last one is **dropped**. With `void`, a write reached the bus,
the bus emitted, and no listener ever ran again — screens kept their pre-write numbers and
the ledger never reloaded after a sync. The payload is the notification count, so every
emission is a change. (Found by `tool/ui_db_verify.dart`, which noticed that a write
changed the database and not the screen.)

### The database is what bumps it

`ChangeBus.attachTo(db)` sets `KhataDatabase.changeSink`, and `KhataDatabase` fires it
from the one place every write passes through: an override of `customStatement`, plus a
transaction-depth counter so that

* **one transaction is one notification** (a 40-op sync batch is not 40 rebuilds), and
* **a rolled-back transaction is no notification** — the integrity gate refusing a write
  must not tell the UI to re-read rows that never existed.

The point of wiring it there rather than at call sites: a local edit, an invoice, a sync
batch applied by the pipeline, a backup restore and a settings change all bump the same
signal, and **no screen can be stale because somebody forgot a line**. Which is also why
`tool/ui_db_verify.dart` never calls `bus.changed()` — the writes are supposed to do it,
and the day they stop, the suite fails.

### A `StreamProvider` starts when it is watched

Worth knowing before writing a screen: `container.read(someStreamProvider)` **does not
start its stream** — it sits in `AsyncLoading` for ever. Measured, not assumed
(`bin/probe4.dart` in the harness): a stream that yields 42 immediately is still
`AsyncLoading<int>()` 300 ms after a bare `read`, and turns into `AsyncData<int>(42)` the
moment a listener is added.

Consequences that are easy to get wrong:

* widgets are fine — `ref.watch` subscribes;
* `ref.read(provider)` from a button callback reads **nothing**; that is what the command
  objects are for (they write, and the bus notifies);
* and `await provider.future` on a **`StreamProvider`** never completes in Riverpod 3.4.3
  (`$FutureModifier.future` mints the future while the provider is still loading). It is
  correct on `FutureProvider`/`AsyncNotifier`. Screens should render `AsyncValue` with
  `.when(...)`; nothing in the app should `await` a stream provider's future.

### Every await in a notifier is followed by `ref.mounted`

`LedgerController.refresh()` is driven by a *notification*, not by a tap: a sync can land
at the moment the user leaves the ledger screen. Without the guard, writing `state` on a
disposed notifier throws *"Cannot use the Ref … after it has been disposed"* — in a shop,
a crash on the way out of the screen the user was reading. The guard is Riverpod's own
documented advice, and the suite caught the omission as an unhandled exception during
teardown.

---

## 2 · What the state layer guarantees

* **Money is integer minor units end to end.** `MoneyFormat` renders `Rs 97`, lakh/crore
  grouping (`1.23L`, `1.23Cr`) or Western, Urdu digits (`۱۲۳`) when the language is Urdu,
  and `balance()` appends ` Dr`/`Cr` — the sign convention belongs in one place, because
  a wrong sign on a party screen is a wrong number in front of a customer.
* **Dates are epoch-days, formatted through `EpochDay`**, and "today" comes from `v_now`
  (the ledger's timezone and a pinned business day), never from the device clock directly.
* **Charts are `CustomPaint` with arithmetic in `lib/ui/charts/chart_math.dart`** — nice
  ticks, min/max downsampling that keeps the first and last point exactly, bar geometry
  and hit testing. No chart plugin: at 120 fps the honest answer is to own the maths and
  paint it, and it is testable without a render tree (that is the 174-check suite).
* **Lists page and virtualise**: `PagedListController` keeps at most ~480 resident items
  and issues exactly one load per page crossed (30 060-item and 4 000-row walks are both
  asserted, including the property that a back-scroll does not re-load what is resident).
* **The ledger walks backwards from a live anchor.** `LedgerPager.closingBalanceMinor` is
  the party's balance from `v_party_balances`, and the walk must land on zero; when it
  does not, `integrityNote` says so on screen instead of showing plausible numbers. A sync
  that moves the anchor reloads the same list object — which is what preserves the user's
  scroll position.
* **`DisplayPrefs`** (language, grouping, symbol) is a `Notifier`, not a database read, so
  the first frame after unlock needs no query.

## 3 · The queries

`lib/ui/state/queries.dart` holds every read, as named constants, so a slow query is a
one-line change and `tool/ui_db_verify.dart` can run each one against a real database.

> The reason that matters: SQL is a string. Selecting a column that does not exist —
> `name_ur` from `v_stock_on_hand_live` — compiles perfectly and fails at runtime. The
> integration suite executes every query the screens use; that is how this one was found
> before a phone was.

## 4 · Presentation decisions that are not obvious

* **The dashboard's "Cash & bank" card is cash + bank + mobile wallet.** `cash_minor` in
  `v_dashboard_metrics` sums every account with `is_cash = 1`, and the seed marks the bank
  and wallet accounts that way. The card is labelled for what it shows; a card called
  "Cash" that quietly includes the bank is the sort of thing that ends with a shopkeeper
  spending money that is not in the drawer.
* **The dashboard nets advances against receivables.** A customer over-payment reduces
  receivables rather than appearing as a payable, because the rollup is by *account* (at
  `1200` a customer sub-ledger is debit-normal whatever the sign). The per-party split is
  where an advance is named as such, and that is what the party list shows.
* **Receivables and payables roll up the control account *and* its party sub-ledgers**
  (migration 011). Filtering on `role = 'ar'` matched the control only, so credit sales
  were invisible to the dashboard: a shop owed Rs 21 300 was told it was owed Rs 15 000.
* **A party with an unreadable name still gets an account.** Sub-ledger codes are
  `1200·Zubaida Ge-94F92DF1`: the readable part is truncated into the space actually left
  after the prefix (the schema caps codes at 24 characters) and the discriminator comes
  from the *tail* of the UUIDv7, where the randomness is. See §5.

## 5 · Defects this stage found in shipped code

Six, and four of them would have reached a user's phone:

| # | defect | user-visible consequence | fix |
| --- | --- | --- | --- |
| 1 | a party sub-ledger code was `'$controlCode·$shortName'` with only the name truncated to 24 | **no party named longer than 19 characters could be created at all** — "Zubaida General Store" produced a 25-character code, the CHECK rejected the row, `INSERT OR IGNORE` hid it, and the caller got `INT-7` | truncate into the space left after the prefix; discriminate from the id's tail; retry with a wider discriminator on collision |
| 2 | two parties sharing a name prefix produced identical codes | the second party silently failed to get a sub-ledger (same `INT-7`) | as above — and the discriminator is *not* the id's head, which is a millisecond timestamp shared by everything created in the same few hours |
| 3 | `v_dashboard_metrics` filtered receivables/payables on `accounts.role` | the dashboard under-reported what customers owe by every credit sale in the book | migration `011_dashboard_party_rollup.sql` |
| 4 | `UiSql.stock` selected `name_ur` from a view that has no such column | the stock screen would have thrown on open | the query, and every UI query, now runs against a real database in the suite |
| 5 | `ChangeBus` emitted `void` | screens never re-read after a write; a sync landed in the database and nowhere on screen | the signal carries a sequence number |
| 6 | `LedgerController.refresh()` used `ref` after an await with no `ref.mounted` guard | a crash leaving the ledger screen at the wrong moment | guard every post-await use |

Defect 1 is the one to remember: it was invisible to a suite that only ever created parties
called "Ahmed Traders" and "Warn Case". The integration suite exists because *short, tidy
test data hides the class of bug that only appears in real names.*

## 6 · What is not done yet

**The widget layer.** The state layer is what it will render; nothing below it needs to
change. The files, in the order they should be written:

| file | what it holds |
| --- | --- |
| `lib/apps/khata_app.dart` | `MaterialApp.router` + `ProviderScope` overrides (`databaseProvider`, boot-time preferences), theme wiring, `go_router` routes |
| `lib/ui/theme/theme.dart` | `ThemeData` from `tokens.dart` (the palette in `theme/tokens.dart` is already audited by `ui_verify`: contrast ratios, dark/light pairs, semantic names) |
| `lib/ui/widgets/biometric_gate.dart` | the first screen: unlock through the platform security channel, with the "sync may run in the background" state shown honestly (see `docs/SYNC.md` §1) |
| `lib/ui/widgets/virtual_list.dart` | the `ListView.builder` over `PagedListController`/`LedgerPager`, one `RepaintBoundary` per row, scroll-driven `loadMore` |
| `lib/ui/widgets/ledger_view.dart` | the ledger rows: date headers, running balance, `Dr`/`Cr`, the integrity banner |
| `lib/ui/widgets/live_charts.dart` | `CustomPaint` wrappers over `chart_math.dart` — no plugin, no `saveLayer`, `RepaintBoundary` |
| `lib/ui/widgets/skeletons.dart` | loading and empty states, so "no data" never looks like "still loading" |
| `lib/ui/screens/{dashboard,party_list,party_ledger,cash_book,stock_book,staff_book,bill_book,settings}.dart` | eight screens, each: watch a provider → `.when(...)` → render → call a command |
| `lib/ui/commands/book_commands.dart` | the write side: `postSale`, `postInvoice`, `settleInvoice`, `postExpense` behind a command object that takes a `ChangeSink` (`changedNow()` for the save button's own receipt) |

Each screen's data contract already exists and is asserted; the widget layer is
presentation over it. Two constraints to keep while writing it:

* **Impeller / 120 fps:** no `saveLayer`, no layout work in `build` hot paths, `const`
  constructors, `RepaintBoundary` on charts and long lists, and no arithmetic in widgets —
  if a number is computed, it belongs in the verified layer.
* **Never `ref.read` a stream provider from a callback** (§1 — it reads nothing). Call a
  command; the bus notifies.

**What must be checked on a real device** (nothing in this section can be proven here):

* the goldens and the first real frame times — Impeller behaviour, Urdu Nastaliq shaping
  and line height, and whether the 16 ms budget holds while a sync is applying batches
  (the coalescing means at most one re-read per window, but only a device can show the
  frame graph);
* that `LocalAuthentication` on the unlock screen still allows the background sync path
  (the custody design in `docs/SYNC.md` §1 is what makes this possible; the prompt itself
  is a device behaviour);
* keyboard and text rendering for Urdu input, and RTL mirroring of the pager and charts;
* `flutter build apk --release` / `build ipa` — the first compile of the widget layer, and
  the first place a Flutter framework API mismatch shows up.
