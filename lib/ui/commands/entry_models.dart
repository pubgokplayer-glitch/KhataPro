/// KhataPro · what an entry form collects, and what a screen tells the sheet to do.
///
/// ## Why these two classes are not in `widgets/forms.dart`
///
/// Because they are not widgets. `EntrySheetValues` is five fields of data and
/// `EntrySheetSpec` is a title, four flags and a callback — nothing here draws anything, and
/// nothing here imports `package:flutter`. Keeping them in the widget file made the whole write
/// path unreachable from a plain `dart run` (a tool cannot import `package:flutter/material.dart`
/// outside a Flutter build), which meant the specs could only be checked by *reading* them.
///
/// The user's directive for this batch was specific: *"the bill spec posts to the supplier
/// side"* has to be a check, not a comment. [`entry_specs.dart`](entry_specs.dart) builds these
/// two objects for all six entry types; `tool/ui_commands_verify.dart` drives them against a real
/// SQLCipher book, with no widget tree anywhere in the process. That is only possible because
/// the model is on this side of the line and the sheet is on the other.
///
/// `widgets/forms.dart` imports and re-exports both, so the screens' own imports are unchanged.
library;

import '../../data/db/dao/parties_dao.dart' show PartyKind;
import 'book_commands.dart';

/// What the sheet collects.
final class EntrySheetValues {
  const EntrySheetValues({
    required this.amountMinor,
    required this.entryDate,
    required this.toBank,
    this.partyId,
    this.memo,
  });

  final int amountMinor;
  final int entryDate;

  /// Money left/entered the bank rather than the drawer. Shown only when the spec asks.
  final bool toBank;

  final String? partyId;
  final String? memo;
}

/// What a screen tells the sheet to do.
final class EntrySheetSpec {
  const EntrySheetSpec({
    required this.title,
    required this.saveLabel,
    required this.onSave,
    this.needsParty = false,
    this.partyKind = PartyKind.customer,
    this.lockedPartyId,
    this.lockedPartyName,
    this.allowBank = false,
    this.initialAmountMinor,
    this.initialDate,
    this.initialMemo,
    this.amountLabel,
    this.hint,
  });

  final String title;
  final String saveLabel;

  /// Runs the command. The sheet awaits it and closes itself only when `outcome.ok` — a
  /// refusal keeps the form on screen with the numbers still in it.
  final Future<CommandOutcome> Function(EntrySheetValues values) onSave;

  final bool needsParty;
  final int partyKind;

  /// Set when the sheet was opened *from* a party's own screen: the party is then a fact, not
  /// a choice, and showing a picker would invite the user to post a receipt to the wrong
  /// ledger by mistake.
  final String? lockedPartyId;
  final String? lockedPartyName;

  final bool allowBank;
  final int? initialAmountMinor;
  final int? initialDate;
  final String? initialMemo;
  final String? amountLabel;
  final String? hint;
}


