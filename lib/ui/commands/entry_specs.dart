/// KhataPro · the write specs: what each of the six entries actually posts.
///
/// The `EntrySheet` knows how to collect an amount, a date, a party and a note. It does not
/// know — and must not know — whether those become a sale, a bill or a receipt. That mapping
/// is here, in one pure-Dart file with one function per entry type, and it is pure so the
/// sweep can assert it: `tool/ui_verify.dart` checks that the sale spec calls `recordSale`
/// with the sale's rules and that the bill spec posts to the *supplier* side, which is the
/// check that would have caught a purchase bill going through the sales path.
///
/// Every spec shares the same shape, because every screen shares the same problem: the user
/// is standing in front of a form, and the only thing that differs is which command runs and
/// which fields are on screen.
library;

import '../../data/db/dao/base_dao.dart' show AccountRole;
import '../../data/db/dao/parties_dao.dart' show PartyKind;
import '../format/formatting.dart';
import '../format/strings.dart';
import 'entry_models.dart';
import 'book_commands.dart';

/// A cash sale: goods out, money in, no document.
EntrySheetSpec saleSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  int? initialDate,
}) =>
    EntrySheetSpec(
      title: strings.newSale,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.saleHint,
      initialDate: initialDate,
      allowBank: false,
      onSave: (values) => commands.recordSale(
        entryDate: values.entryDate,
        grossMinor: values.amountMinor,
        amountPaidMinor: values.amountMinor,
        money: money,
        memo: values.memo,
      ),
    );

/// A credit sale with a document behind it — the one that creates a receivable, ages, and can
/// be sent as a reminder.
EntrySheetSpec invoiceSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  String? partyId,
  String? partyName,
  int? initialDate,
}) =>
    EntrySheetSpec(
      title: strings.newInvoice,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.invoiceHint,
      needsParty: true,
      partyKind: PartyKind.customer,
      lockedPartyId: partyId,
      lockedPartyName: partyName,
      initialDate: initialDate,
      allowBank: false,
      // The whole amount goes on credit: this is the form for "he took it on the book". A
      // customer paying part of it at the counter is the *receipt* form's job, and keeping
      // them separate is what stops the two from double-counting the same cash.
      onSave: (values) => commands.recordInvoice(
        entryDate: values.entryDate,
        grossMinor: values.amountMinor,
        amountPaidMinor: 0,
        partyId: values.partyId ?? partyId ?? '',
        money: money,
        dueDate: values.entryDate + 30,
        memo: values.memo,
      ),
    );

/// Money in against a party's balance, without naming a document.
EntrySheetSpec receiptSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  required String partyId,
  String? partyName,
  int? initialAmountMinor,
  int? initialDate,
}) =>
    EntrySheetSpec(
      title: strings.newReceipt,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.receiptHint,
      needsParty: true,
      partyKind: PartyKind.customer,
      lockedPartyId: partyId,
      lockedPartyName: partyName,
      allowBank: true,
      initialAmountMinor: initialAmountMinor,
      initialDate: initialDate,
      onSave: (values) => commands.recordReceipt(
        entryDate: values.entryDate,
        amountMinor: values.amountMinor,
        partyId: partyId,
        money: money,
        toBank: values.toBank,
        memo: values.memo,
      ),
    );

/// An expense paid from the drawer or the bank.
EntrySheetSpec expenseSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  int? initialAmountMinor,
  int? initialDate,
}) =>
    EntrySheetSpec(
      title: strings.newExpense,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.expenseHint,
      allowBank: true,
      initialAmountMinor: initialAmountMinor,
      initialDate: initialDate,
      onSave: (values) => commands.recordExpense(
        entryDate: values.entryDate,
        amountMinor: values.amountMinor,
        money: money,
        fromBank: values.toBank,
        memo: values.memo,
      ),
    );

/// A supplier bill (or a service bill, when [debitRole] is an expense).
EntrySheetSpec billSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  String? partyId,
  String? partyName,
  String debitRole = AccountRole.inventory,
  int? initialDate,
}) =>
    EntrySheetSpec(
      title: strings.newSupplierBill,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.billHint,
      needsParty: true,
      partyKind: PartyKind.supplier,
      lockedPartyId: partyId,
      lockedPartyName: partyName,
      allowBank: false,
      initialDate: initialDate,
      onSave: (values) => commands.recordBill(
        entryDate: values.entryDate,
        grossMinor: values.amountMinor,
        amountPaidMinor: 0,
        partyId: values.partyId ?? partyId ?? '',
        money: money,
        debitRole: debitRole,
        dueDate: values.entryDate + 30,
        memo: values.memo,
      ),
    );

/// Settling an existing **sales** document: money in, allocated.
EntrySheetSpec settleInvoiceSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  required String documentId,
  required int balanceMinor,
  String? partyName,
  bool fromBank = false,
}) =>
    EntrySheetSpec(
      title: strings.receivePayment,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.settleInvoiceHint(partyName, money.balance(balanceMinor)),
      allowBank: true,
      initialAmountMinor: balanceMinor,
      onSave: (values) => commands.settleInvoice(
        entryDate: values.entryDate,
        amountMinor: values.amountMinor,
        documentId: documentId,
        money: money,
        toBank: values.toBank,
        memo: values.memo,
      ),
    );

/// Settling a **purchase** document: money out, allocated against the supplier's bill.
EntrySheetSpec settleBillSpec({
  required BookCommands commands,
  required MoneyFormat money,
  required UiStrings strings,
  required String documentId,
  required int balanceMinor,
  String? partyName,
}) =>
    EntrySheetSpec(
      title: strings.paySupplier,
      saveLabel: strings.postEntry,
      amountLabel: strings.amount,
      hint: strings.settleBillHint(partyName, money.balance(balanceMinor)),
      allowBank: true,
      initialAmountMinor: balanceMinor,
      onSave: (values) => commands.settleBill(
        entryDate: values.entryDate,
        amountMinor: values.amountMinor,
        documentId: documentId,
        money: money,
        fromBank: values.toBank,
        memo: values.memo,
      ),
    );
