/// KhataPro · where a link lands, and what each link opens.
///
/// This file exists because [`deep_links.dart`](../apps/deep_links.dart) deliberately knows
/// nothing about widgets: it turns a uri into a route, an id and a source string, and stops
/// there. The *destination* half — which of the eight screens a `partyLedger` link opens, and
/// which form a `partyReceipt` link opens once the screen is there — needs the screen types and
/// the write specs, so it lives in the UI tree, here.
///
/// The split is what makes the whole thing testable. `parseDeepLink` is pure (no Flutter
/// import at all), so `tool/ui_verify.dart` can throw thirty malformed uris at it without a
/// widget tree; [routeFor] is a pure mapping over that result, so the same suite can assert
/// that `khatapro://party/<uuid>` opens the *party's* ledger rather than the tab bar's
/// `/parties`. Both halves are checked there, and the router in
/// [`khata_app.dart`](../apps/khata_app.dart) only has to pick between them.
///
/// ## The three shapes a link arrives in
///
/// 1. **Cold start** — the process was not running. The engine hands the uri to
///    `WidgetsBinding.instance.platformDispatcher.defaultRouteName` before the first frame, and
///    `KhataRouter` uses it as `initialLocation`. This is the reminder tapped from a lock
///    screen, which is the common case: the phone was in the shopkeeper's pocket.
/// 2. **Warm start** — the app was running behind the message. The engine calls
///    `didPushRouteInformation` on every registered `WidgetsBindingObserver`; `KhataRouter` is
///    one, so a second reminder tapped while the app is open does not do nothing.
/// 3. **In-app** — a button builds a link with [buildPartyLink]/[buildBillLink] and pushes it,
///    which is how "remind" on the ledger screen reaches the same code path as a customer's
///    tap. One path, three entrances.
library;

import '../apps/deep_links.dart';
import 'commands/book_commands.dart';
import 'commands/entry_specs.dart';
import 'format/formatting.dart';
import 'format/strings.dart';
import 'commands/entry_models.dart';

/// The route a parsed link opens.
///
/// The return type is deliberately `Object` and not a records/union class: the values are
/// either a `String` location for the seven flat screens, or a [GoScreen] for the two
/// parameterised ones (`/party/:partyId`, `/bills?doc=…`), and `Object` is the type that says
/// "exactly one of these two" without a sealed hierarchy for two cases. Callers use a
/// `switch` with a type pattern, which is exhaustive because of the final `else` the compiler
/// demands.
Object routeFor(KhataDeepLink link) => switch (link.location) {
      KhataRoutes.dashboard => KhataRoutes.dashboard,
      KhataRoutes.parties => KhataRoutes.parties,
      KhataRoutes.cash => KhataRoutes.cash,
      KhataRoutes.bills => KhataRoutes.bills,
      KhataRoutes.stock => KhataRoutes.stock,
      KhataRoutes.staff => KhataRoutes.staff,
      KhataRoutes.settings => KhataRoutes.settings,
      _ => _parameterised(link),
    };

/// The two links that carry a value, and the fallback.
Object _parameterised(KhataDeepLink link) {
  final partyId = link.partyId;
  if (partyId != null && partyId.isNotEmpty) {
    final action = actionOf(link);
    return GoScreen(
      '${KhataRoutes.partyLedger(partyId)}${_actionQuery(action)}',
      partyId: partyId,
      action: action,
    );
  }
  final documentId = link.documentId;
  if (documentId != null && documentId.isNotEmpty) {
    return GoScreen(KhataRoutes.bill(documentId), documentId: documentId);
  }
  final ticket = link.ticket;
  if (ticket != null && ticket.isNotEmpty) {
    return GoScreen(KhataRoutes.join(ticket), ticket: ticket);
  }
  // A link that is ours but says nothing: `/join` without a ticket, or a path segment that
  // survived parsing but emptied out. The dashboard, rather than an error page — the user
  // tapped a link into this app and the app opened; explaining an empty id is noise.
  return KhataRoutes.dashboard;
}

/// The query string an action needs, or empty. Written out rather than derived from the enum's
/// name, so renaming a value cannot silently change a link that is already in someone's
/// WhatsApp history.
String _actionQuery(LinkAction action) => switch (action) {
      LinkAction.open => '',
      LinkAction.receive => '?action=receive',
    };

/// A screen that needs a parameter, as the router needs to see it.
final class GoScreen {
  const GoScreen(
    this.path, {
    this.partyId,
    this.documentId,
    this.ticket,
    this.action = LinkAction.open,
  });

  final String path;
  final String? partyId;
  final String? documentId;
  final String? ticket;

  /// What the link asked for once it has landed. Carried here, and **inside** [path], so the
  /// router — which only ever sees a location — does not drop it.
  final LinkAction action;

  /// Whether the parameter is expected to resolve to a row *in this book*. A link from
  /// another shop's phone parses fine and then lands on an id this database has never seen;
  /// the router answers that with the error page, because "this party is not in your khata"
  /// is something the user has to be told.
  bool get expectsRow => partyId != null || documentId != null;

  @override
  String toString() => 'GoScreen($path)';
}

/// **A second role for the same link.** A link is not only a place to arrive — it is also an
/// intention, and the two are not always the same screen.
///
/// `khatapro://party/<id>?action=receive` is what the ledger screen's *Receive* button builds
/// when it hands work to a notification: the user tapped "receive", put the phone down, and
/// came back through the message. Following the link to the ledger and then doing nothing
/// would lose the intent, so the party screen reads the action and opens the matching entry
/// form once its own row has loaded.
///
/// Only one action exists, and it is **money in** — deliberately. There is no money-out form a
/// party link could open, because the write API has no "paid a supplier, no bill named"
/// command: money leaves the drawer by settling a bill ([`settleBillSpec`]) or by booking an
/// expense, and neither is something to open from a uri that may have sat in a chat thread for
/// a week. So `?action=pay` parses, and lands on the ledger, where the shopkeeper can see the
/// bills and settle the right one. The rest of the six entries change the *books* (prices,
/// items, parties) and a link must not do that silently on a phone someone else held.
enum LinkAction { open, receive }

/// Reads the action out of a parsed link.
LinkAction actionOf(KhataDeepLink link) {
  final uri = Uri.tryParse(link.source ?? '');
  final raw = (uri?.queryParameters['action'] ?? '').toLowerCase();
  return switch (raw) {
    'receive' || 'in' => LinkAction.receive,
    // `pay`, `out`, and every other word land on [LinkAction.open]: the ledger, not a form.
    _ => LinkAction.open,
  };
}

/// The screen a party link opens, and the action it carries, in one value — so a screen reads
/// the pair once instead of parsing the uri a second time.
final class PartyLink {
  const PartyLink({required this.partyId, required this.action});
  final String partyId;
  final LinkAction action;
}

/// Pulls a [PartyLink] out of a uri, or `null` when it is not a party link for this app.
PartyLink? partyLinkOf(Uri uri) {
  final link = parseDeepLink(uri);
  final partyId = link?.partyId;
  if (link == null || partyId == null || partyId.isEmpty) return null;
  return PartyLink(partyId: partyId, action: actionOf(link));
}

/// The doc id in `/bills?doc=…`, for the bill book's one-shot open.
String? documentIdOf(Uri uri) {
  final link = parseDeepLink(uri);
  final documentId = link?.documentId;
  return documentId == null || documentId.isEmpty ? null : documentId;
}

// ── the entry form a screen opens ────────────────────────────────────────────

/// Everything the six forms need that is *not* the books: the display preferences, the
/// strings, and the two write specs that a link can reach directly.
final class EntryForms {
  const EntryForms({required this.commands, required this.money, required this.strings});

  final BookCommands commands;
  final MoneyFormat money;
  final UiStrings strings;
}

/// The form a link action opens, or `null` for a plain link that only navigates.
///
/// Kept here, next to [routeFor], because it is the same decision: a link says *where* and
/// *what*, and having the two answers three files apart is how a "receive" button ends up
/// opening an invoice.
EntrySheetSpec? formFor({
  required LinkAction action,
  required EntryForms forms,
  String? partyId,
  String? partyName,
}) {
  if (action == LinkAction.open || partyId == null || partyId.isEmpty) return null;
  return receiptSpec(
    commands: forms.commands,
    money: forms.money,
    strings: forms.strings,
    partyId: partyId,
    partyName: partyName,
  );
}
