/// KhataPro · the reminder sheet: the message, ready to paste.
///
/// This project ships **no messaging plugin**. `url_launcher` and `share_plus` are two more
/// dependencies, two more platform channels and two more failure modes (a handler that is not
/// installed, an intent that needs a permission) for something the operating system already
/// does. What the app can do without any of that is the *hard* part: write the right sentence,
/// in the right language, with the right amount and a link that opens the customer's ledger.
///
/// So the sheet shows the message and copies it. The shopkeeper pastes it into the SMS thread
/// or the WhatsApp chat that is already open — which is how these reminders are actually sent
/// anyway, because the customer is a contact, not a phone number.
///
/// A one-line native intent (`Intent.ACTION_SENDTO` on Android, `UIApplication.open` on iOS)
/// turns this into one tap and is on the D5 list next to the Drive and iCloud targets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';

/// Shows [body] with a copy button. Returns true when the user copied it.
Future<void> showReminderSheet(
  BuildContext context, {
  required String title,
  required String body,
  String? phone,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => _ReminderSheet(title: title, body: body, phone: phone),
  );
}

class _ReminderSheet extends StatefulWidget {
  const _ReminderSheet({required this.title, required this.body, this.phone});

  final String title;
  final String body;
  final String? phone;

  @override
  State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: text.titleMedium),
            const SizedBox(height: Spacing.sm),
            if (widget.phone != null)
              Text(
                widget.phone!,
                style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
              ),
            const SizedBox(height: Spacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: colors.outline),
              ),
              child: Text(widget.body, style: text.bodyMedium?.copyWith(height: 1.5)),
            ),
            const SizedBox(height: Spacing.md),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: widget.body));
                if (!mounted) return;
                setState(() => _copied = true);
              },
              child: Row(
                children: [
                  Icon(_copied ? Icons.check : Icons.share, size: 18, color: colors.brand),
                  const SizedBox(width: Spacing.sm),
                  Text(
                    _copied ? 'Copied — paste it into SMS or WhatsApp' : 'Copy the message',
                    style: text.bodyMedium?.copyWith(color: colors.brand),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
