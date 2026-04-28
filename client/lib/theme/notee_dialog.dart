// NoteeDialog + helpers — paper-tonal modals that match the design handoff
// instead of Material's default AlertDialog look.
//
// - Surface: `t.toolbar` (cream) with 0.5px outline + soft shadow
// - 14px corner radius
// - Newsreader serif title, mono uppercase field label
// - Outlined input (no Material underline)
// - Cancel = text button (inkDim), Create/primary = filled ink button

import 'package:flutter/material.dart';

import 'notee_theme.dart';

/// Modal scrim + paper-toned card. Children laid out top-to-bottom.
class NoteeDialog extends StatelessWidget {
  const NoteeDialog({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.maxWidth = 380,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: t.toolbar,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.tbBorder, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 40,
                offset: const Offset(0, 16),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: t.ink,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 14),
              ...children,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Mono uppercase eyebrow + slim outlined input — replaces Material's
/// underline TextField inside dialogs.
class NoteeFormField extends StatelessWidget {
  const NoteeFormField({
    super.key,
    required this.label,
    required this.controller,
    this.autofocus = false,
    this.hint,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final bool autofocus;
  final String? hint;
  final void Function(String)? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label.toUpperCase(),
          style: noteeSectionEyebrow(t),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.tbBorder, width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: controller,
            autofocus: autofocus,
            cursorColor: t.accent,
            cursorWidth: 1.4,
            style: TextStyle(
              fontFamily: 'Inter Tight',
              fontSize: 14,
              color: t.ink,
              height: 1.2,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(color: t.inkFaint),
              contentPadding: EdgeInsets.zero,
            ),
            onSubmitted: onSubmitted,
          ),
        ),
      ],
    );
  }
}

/// Body paragraph — used by confirm dialogs.
class NoteeDialogBody extends StatelessWidget {
  const NoteeDialogBody(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'Inter Tight',
        fontSize: 13.5,
        color: t.inkDim,
        height: 1.45,
      ),
    );
  }
}

/// Text button — used as the secondary "Cancel" action.
class NoteeTextButton extends StatelessWidget {
  const NoteeTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final color = danger ? const Color(0xFFC62828) : t.inkDim;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(9)),
        ),
        textStyle: TextStyle(
          fontFamily: 'Inter Tight',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: color,
          height: 1.2,
        ),
      ),
      child: Text(label),
    );
  }
}

/// Filled "primary" action — solid ink-on-paper.
class NoteePrimaryButton extends StatelessWidget {
  const NoteePrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final bg = danger ? const Color(0xFFB02A2A) : t.ink;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: t.page,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(9)),
        ),
        textStyle: const TextStyle(
          fontFamily: 'Inter Tight',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      child: Text(label),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────

/// Show a Notee-styled prompt that returns the entered name (trimmed) or
/// null if cancelled.
Future<String?> noteeAskName(
  BuildContext context, {
  required String title,
  String fieldLabel = 'Name',
  String? initial,
  String confirmLabel = 'Create',
}) async {
  final ctl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (ctx) => NoteeDialog(
      title: title,
      actions: [
        NoteeTextButton(
          label: 'Cancel',
          onPressed: () => Navigator.pop(ctx),
        ),
        NoteePrimaryButton(
          label: confirmLabel,
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
        ),
      ],
      children: [
        NoteeFormField(
          label: fieldLabel,
          controller: ctl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ],
    ),
  );
}

/// Confirmation dialog returning true if the user confirmed. The "danger"
/// flag flips the primary button to a red destructive style.
Future<bool> noteeConfirm(
  BuildContext context, {
  required String title,
  required String body,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Delete',
  bool danger = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (ctx) => NoteeDialog(
      title: title,
      actions: [
        NoteeTextButton(
          label: cancelLabel,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        NoteePrimaryButton(
          label: confirmLabel,
          danger: danger,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
      children: [NoteeDialogBody(body)],
    ),
  );
  return ok ?? false;
}
