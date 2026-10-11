/// KhataPro · what tells the UI that the books changed.
///
/// ## Why there is a bus instead of `watch()`
///
/// Drift can keep a query live for you, and the app would be simpler if it could. It
/// cannot, for two documented reasons:
///
///  * every screen in this app reads a **view** (`v_dashboard_metrics`,
///    `v_party_balances`, `v_document_outstanding` …), and a `customSelect` over a view
///    has no table to subscribe to — `customSelect` with an empty `readsFrom` builds a
///    `MultipleUpdateQuery`, whose `matches` is `queries.any(...)`, which is `false` for
///    an empty set. The stream would emit once and never again;
///  * the write path is raw SQL (`customStatement`), and drift's own documentation is
///    explicit: *"This method does not update stream queries on this drift database."*
///
/// The alternative — hand-writing `TableInfo` objects for 38 tables to feed `readsFrom` —
/// would be a lie in a different costume: those tables exist in DDL, not in generated
/// Dart classes, so any object I made up would match nothing a real writer signals.
///
/// So the invalidation is explicit: [ChangeBus] carries one signal, and **every write in
/// the app goes through a place that bumps it**. The UI re-fetches what it is showing.
/// For these queries — a handful of small aggregate reads per screen — that is cheap, and
/// it has a property that matters more than cleverness: when a screen is wrong, the bug
/// is in one of two places, and both are visible in one file.
///
/// A background sync landing is the same signal as a local edit. That is not a
/// simplification — it is the point: the screen cannot tell who wrote a row, so it must
/// not behave differently for the two cases.
library;

import 'dart:async';

import '../../data/db/database.dart';

/// The coalescing window. A single user action can touch many rows (a posted invoice
/// writes `journal_entries`, `journal_lines`, `documents`, `stock_moves`, `oplog`,
/// `audit_log`…), and a sync batch can apply thousands of operations at once. Bumping a
/// signal per write would rebuild every listening screen per row, which is exactly the
/// "background sync janks the UI" failure this app must not have. One notification per
/// frame is the most a screen can consume anyway.
const Duration kChangeCoalesceWindow = Duration(milliseconds: 16);

final class ChangeBus implements ChangeSink {
  ChangeBus({this.coalesce = kChangeCoalesceWindow});

  /// How long to wait after the first bump before notifying. Zero is for tests and for
  /// callers that need a synchronous guarantee.
  final Duration coalesce;

  final _controller = StreamController<int>.broadcast();
  Timer? _pending;
  var _bumps = 0;
  var _notifications = 0;
  var _closed = false;

  /// Emits once per coalesced window in which at least one write happened. Broadcast, so
  /// ten screens cost one subscription each and one re-fetch each — not one per screen
  /// per write.
  ///
  /// **The event carries the notification count, and that is load-bearing.** This was
  /// `Stream<void>` first, and it silently did not work: a `StreamProvider<void>` produces
  /// `AsyncData(null)` for ever, Riverpod compares states and drops an emission that is
  /// equal to the last one, so no listener ever fired again. Screens kept their pre-write
  /// numbers and the ledger never reloaded after a sync. A monotonically increasing `int`
  /// makes every emission a *change*, which is the only thing Riverpod will deliver.
  /// Found by `tool/ui_db_verify.dart` (a write, then a wait, then a look at the pixels'
  /// worth of state).
  Stream<int> get changes => _controller.stream;

  /// Attaches this bus to the database, so that **every** committed write bumps it —
  /// a local edit, an invoice, a sync batch applied by the pipeline, a restored backup.
  ///
  /// This is the whole reason the bus exists rather than drift's stream queries: the
  /// notification is a property of the write, not of a call site, so no screen can be
  /// stale because somebody forgot a line. `KhataDatabase` fires it once per committed
  /// transaction (and never for a rolled-back one) — see `database.dart`.
  void attachTo(KhataDatabase db) {
    db.changeSink = bump;
  }

  /// How many writes were reported, and how many notifications they produced. Exposed
  /// because "the UI rebuilds once per frame at most" is a claim that deserves a number
  /// behind it — `tool/ui_verify.dart` asserts a 500-write batch produces one
  /// notification.
  int get bumps => _bumps;
  int get notifications => _notifications;

  /// Reports that the books changed. Cheap enough to call after every write.
  ///
  /// Named both ways on purpose: [bump] reads well at the call site inside the data
  /// layer, and [changed] is the [ChangeSink] method a command takes. A Dart extension
  /// cannot implement an interface, so the adapter has to be these two lines rather than
  /// a separate wrapper class nobody would thank me for.
  @override
  void changed() => bump();

  /// Reports a change that must be visible to the next read in the same microtask.
  @override
  void changedNow() => bumpNow();

  void bump() {
    if (_closed) return;
    _bumps += 1;
    if (coalesce == Duration.zero) {
      _notify();
      return;
    }
    _pending ??= Timer(coalesce, _notify);
  }

  /// Reports a change *now*, skipping the coalescing window. Used by
  /// [BookCommands] when a caller explicitly needs to read its own write back
  /// immediately — the save button's receipt, for instance.
  void bumpNow() {
    if (_closed) return;
    _bumps += 1;
    _notify();
  }

  void _notify() {
    _pending?.cancel();
    _pending = null;
    if (_closed) return;
    _notifications += 1;
    // The payload is the sequence number: see [changes].
    _controller.add(_notifications);
  }

  /// Flushes any pending notification immediately. Called on app pause so a backgrounded
  /// app is not holding a timer, and by tests that want deterministic behaviour.
  void flush() {
    if (_pending != null) _notify();
  }

  Future<void> dispose() async {
    _closed = true;
    _pending?.cancel();
    _pending = null;
    await _controller.close();
  }
}

/// The seam that lets a widget layer say "this is a write, tell everyone" without
/// importing the database. Every command in `book_commands.dart` takes one of these.
abstract interface class ChangeSink {
  void changed();

  /// A change that must be visible to the next read in the same microtask.
  void changedNow();
}
