/// KhataPro · the two toasts the write path needs, and nothing else.
///
/// This is the only part of `lib/ui/commands/` that touches Flutter, split out so the command
/// layer itself stays pure Dart and can be driven by the headless sweep
/// (`tool/ui_commands_verify.dart`). It is deliberately tiny: a saved entry and a refused one
/// are the only two things a shopkeeper is ever told after pressing save.
library;

import 'package:flutter/material.dart';

import '../commands/book_commands.dart';
import '../theme/theme.dart';

/// Shows a command's outcome.
///
/// A refusal is the one message in this app that must not be missed, so it behaves
/// differently from a success: it takes the critical colour, it stays on screen eight seconds
/// instead of three, and it carries the invariant code — the string the user can quote when
/// they ask for help. Success is a quiet confirmation with the entry number, because a
/// shopkeeper who just sold something does not want to read a paragraph.
void showOutcome(BuildContext context, CommandOutcome outcome) {
  final colors = KhataTheme.colorsOf(context);
  final text = _compose(outcome);

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: TextStyle(color: outcome.ok ? colors.onCanvas : colors.critical),
      ),
      backgroundColor: colors.surface,
      duration: Duration(seconds: outcome.ok ? 3 : 8),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// The message text, assembled once so a test can assert on it without a widget tree.
String _compose(CommandOutcome outcome) {
  final text = StringBuffer(outcome.message);
  final entryNo = outcome.entryNo;
  if (entryNo != null && !outcome.message.contains(entryNo)) {
    text.write(' · $entryNo');
  }
  if (outcome.warnings.isNotEmpty) {
    text.write('\n${outcome.warnings.join('\n')}');
  }
  if (!outcome.ok && outcome.code != null && !outcome.message.contains(outcome.code!)) {
    text.write('\n(${outcome.code})');
  }
  return text.toString();
}

/// A refusal that has already been turned into words, for a screen that shows the reason
/// inline (the new-entry form does, so the user can fix the amount without re-reading a
/// toast that already vanished).
class OutcomeNotice extends StatelessWidget {
  const OutcomeNotice({super.key, required this.outcome, this.onDismiss});

  final CommandOutcome outcome;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final accent = outcome.ok ? colors.moneyIn : colors.critical;

    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(outcome.ok ? Icons.check : Icons.warning_amber, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _compose(outcome),
              style: TextStyle(color: colors.onCanvas, fontSize: 13, height: 1.4),
            ),
          ),
          if (onDismiss != null)
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: Icon(Icons.close, size: 18, color: colors.onSurfaceMuted),
            ),
        ],
      ),
    );
  }
}
