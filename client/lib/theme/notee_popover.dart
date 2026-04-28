// Anchored popover — paper-toned card that opens below (or above) a
// trigger widget, dismisses on outside tap or escape. The replacement for
// Material's Menu/PopupMenu when we want the Notee aesthetic.

import 'dart:async';

import 'package:flutter/material.dart';

import 'notee_theme.dart';

enum NoteePopoverPlacement { below, above, right, left }

/// Show a popover anchored to [anchorKey]'s widget. Returns a value posted
/// to `Navigator.pop(value)` from inside the popover, or null on dismiss.
Future<T?> showNoteePopover<T>(
  BuildContext context, {
  required GlobalKey anchorKey,
  required Widget Function(BuildContext) builder,
  NoteePopoverPlacement placement = NoteePopoverPlacement.below,
  double offset = 6,
  double maxWidth = 320,
}) {
  final renderBox =
      anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null) return Future.value(null);
  final origin = renderBox.localToGlobal(Offset.zero);
  final size = renderBox.size;
  final screen = MediaQuery.sizeOf(context);

  return showGeneralDialog<T>(
    context: context,
    barrierLabel: 'NoteePopover',
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, anim, _) {
      return _PopoverHost(
        origin: origin,
        anchorSize: size,
        screen: screen,
        placement: placement,
        offset: offset,
        maxWidth: maxWidth,
        animation: anim,
        child: Builder(builder: builder),
      );
    },
    transitionBuilder: (ctx, anim, _, child) {
      // Popovers fade + small upward slide.
      final fade = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.02), end: Offset.zero)
              .animate(fade),
          child: child,
        ),
      );
    },
  );
}

class _PopoverHost extends StatelessWidget {
  const _PopoverHost({
    required this.origin,
    required this.anchorSize,
    required this.screen,
    required this.placement,
    required this.offset,
    required this.maxWidth,
    required this.animation,
    required this.child,
  });

  final Offset origin;
  final Size anchorSize;
  final Size screen;
  final NoteePopoverPlacement placement;
  final double offset;
  final double maxWidth;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Stack(children: [
      // Soft scrim that catches outside taps to dismiss.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).maybePop(),
          child: const SizedBox.shrink(),
        ),
      ),
      _PositionedPopover(
        origin: origin,
        anchorSize: anchorSize,
        screen: screen,
        placement: placement,
        offset: offset,
        maxWidth: maxWidth,
        child: NoteePopoverShell(tokens: t, child: child),
      ),
    ]);
  }
}

class _PositionedPopover extends StatelessWidget {
  const _PositionedPopover({
    required this.origin,
    required this.anchorSize,
    required this.screen,
    required this.placement,
    required this.offset,
    required this.maxWidth,
    required this.child,
  });

  final Offset origin;
  final Size anchorSize;
  final Size screen;
  final NoteePopoverPlacement placement;
  final double offset;
  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _AnchoredDelegate(
        origin: origin,
        anchorSize: anchorSize,
        placement: placement,
        offset: offset,
        maxWidth: maxWidth,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

class _AnchoredDelegate extends SingleChildLayoutDelegate {
  _AnchoredDelegate({
    required this.origin,
    required this.anchorSize,
    required this.placement,
    required this.offset,
    required this.maxWidth,
  });

  final Offset origin;
  final Size anchorSize;
  final NoteePopoverPlacement placement;
  final double offset;
  final double maxWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(c.biggest).deflate(const EdgeInsets.all(12));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (placement == NoteePopoverPlacement.right ||
        placement == NoteePopoverPlacement.left) {
      double x;
      if (placement == NoteePopoverPlacement.right) {
        x = origin.dx + anchorSize.width + offset;
        if (x + childSize.width > size.width - 8) {
          x = origin.dx - childSize.width - offset;
        }
      } else {
        x = origin.dx - childSize.width - offset;
        if (x < 8) x = origin.dx + anchorSize.width + offset;
      }
      if (x < 8) x = 8;
      var y = origin.dy + anchorSize.height / 2 - childSize.height / 2;
      if (y + childSize.height > size.height - 8) {
        y = size.height - childSize.height - 8;
      }
      if (y < 8) y = 8;
      return Offset(x, y);
    }

    // Horizontal: try to align to anchor's left, then nudge into screen.
    var x = origin.dx;
    if (x + childSize.width > size.width - 8) {
      x = size.width - childSize.width - 8;
    }
    if (x < 8) x = 8;

    double y;
    if (placement == NoteePopoverPlacement.above) {
      y = origin.dy - childSize.height - offset;
      if (y < 8) y = origin.dy + anchorSize.height + offset;
    } else {
      y = origin.dy + anchorSize.height + offset;
      if (y + childSize.height > size.height - 8) {
        y = origin.dy - childSize.height - offset;
      }
    }
    if (y < 8) y = 8;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AnchoredDelegate old) =>
      old.origin != origin ||
      old.anchorSize != anchorSize ||
      old.placement != placement;
}

/// Paper-toned shell. Public so non-anchored popovers (long-press menus)
/// can reuse the chrome.
class NoteePopoverShell extends StatelessWidget {
  const NoteePopoverShell({
    super.key,
    required this.child,
    required this.tokens,
    this.padding = const EdgeInsets.all(12),
  });
  final Widget child;
  final NoteeTokens tokens;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.toolbar,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tokens.tbBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: padding,
        child: child,
      ),
    );
  }
}

/// Convenience: a Notee-styled popover menu — vertical list of items, each
/// with optional icon + label. Returns the selected value.
Future<T?> showNoteeMenu<T>(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<NoteeMenuItem<T>> items,
  NoteePopoverPlacement placement = NoteePopoverPlacement.below,
  double offset = 6,
  double maxWidth = 240,
}) {
  return showNoteePopover<T>(
    context,
    anchorKey: anchorKey,
    placement: placement,
    offset: offset,
    maxWidth: maxWidth,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          if (item.divider)
            const _Divider()
          else
            _MenuRow(item: item, onTap: () => Navigator.pop(ctx, item.value)),
      ],
    ),
  );
}

/// Position-based variant — useful for right-click / long-press context menus
/// where no anchor widget exists. [position] is in global screen coordinates.
Future<T?> showNoteePopoverAt<T>(
  BuildContext context, {
  required Offset position,
  Size anchorSize = Size.zero,
  required Widget Function(BuildContext) builder,
  NoteePopoverPlacement placement = NoteePopoverPlacement.below,
  double offset = 0,
  double maxWidth = 320,
}) {
  final screen = MediaQuery.sizeOf(context);
  return showGeneralDialog<T>(
    context: context,
    barrierLabel: 'NoteePopover',
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, anim, _) => _PopoverHost(
      origin: position,
      anchorSize: anchorSize,
      screen: screen,
      placement: placement,
      offset: offset,
      maxWidth: maxWidth,
      animation: anim,
      child: Builder(builder: builder),
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final fade = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.02), end: Offset.zero)
              .animate(fade),
          child: child,
        ),
      );
    },
  );
}

/// A **non-modal** passthrough popover — shows as an overlay that does NOT
/// block pointer events to widgets behind it (canvas drawing still works).
/// [builder] receives a [dismiss] callback to close the popover.
/// Returns that same [dismiss] callback so the caller can close from outside.
///
/// Used for the pen-style panel where the user wants to keep drawing while
/// adjusting settings.
// Module-level tracker: only one passthrough popover may be open at a time.
// Opening a new one dismisses the previous (e.g. switching from color → width).
VoidCallback? _activePassthroughDismiss;

VoidCallback showNoteePassthroughPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required Widget Function(BuildContext ctx, VoidCallback dismiss) builder,
  NoteePopoverPlacement placement = NoteePopoverPlacement.below,
  double offset = 6,
  double? maxWidth = 320,
  bool replacesActive = true,
  VoidCallback? onDismiss,
}) {
  // Close any other passthrough popover first (unless this is a nested
  // child popover that should coexist with its parent).
  if (replacesActive) {
    _activePassthroughDismiss?.call();
    _activePassthroughDismiss = null;
  }

  final renderBox =
      anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null) {
    onDismiss?.call();
    return () {};
  }
  final origin = renderBox.localToGlobal(Offset.zero);
  final anchorSize = renderBox.size;

  late OverlayEntry entry;
  bool dismissed = false;

  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    try {
      entry.remove();
    } catch (_) {}
    if (identical(_activePassthroughDismiss, dismiss)) {
      _activePassthroughDismiss = null;
    }
    onDismiss?.call();
  }

  entry = OverlayEntry(builder: (ctx) {
    final screen = MediaQuery.sizeOf(ctx);
    final t = NoteeProvider.of(ctx).tokens;

    // Compute position.
    double left;
    final double top;
    final mw = maxWidth ?? 600;
    if (placement == NoteePopoverPlacement.right) {
      left = origin.dx + anchorSize.width + offset;
      if (left + mw > screen.width - 8) {
        left = origin.dx - mw - offset;
      }
      top = (origin.dy + anchorSize.height / 2 - 100)
          .clamp(8.0, screen.height - 8.0);
    } else if (placement == NoteePopoverPlacement.left) {
      left = origin.dx - mw - offset;
      if (left < 8) left = origin.dx + anchorSize.width + offset;
      top = (origin.dy + anchorSize.height / 2 - 100)
          .clamp(8.0, screen.height - 8.0);
    } else {
      left = origin.dx;
      if (placement == NoteePopoverPlacement.above) {
        top = (origin.dy - offset - 240).clamp(8.0, screen.height - 8.0);
      } else {
        top = (origin.dy + anchorSize.height + offset)
            .clamp(8.0, screen.height - 8.0);
      }
    }
    if (left + mw > screen.width - 8) {
      left = screen.width - mw - 8;
    }
    if (left < 8) left = 8;

    final content = Material(
      color: Colors.transparent,
      child: NoteePopoverShell(
        tokens: t,
        child: maxWidth != null
            ? ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: builder(ctx, dismiss),
              )
            : IntrinsicWidth(child: builder(ctx, dismiss)),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: dismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: content,
        ),
      ],
    );
  });

  Overlay.of(context).insert(entry);
  if (replacesActive) _activePassthroughDismiss = dismiss;
  return dismiss;
}

/// Dismiss any open passthrough popover (color/width modal). Call this
/// before opening a modal popover (e.g. Settings) so only one is visible.
void dismissActivePassthroughPopover() {
  _activePassthroughDismiss?.call();
  _activePassthroughDismiss = null;
}

// Module-level active menu tracker so a new right-click dismisses the old menu.
VoidCallback? _activeMenuDismiss;

/// Position-based context menu. [position] is in global screen coordinates.
/// Uses an OverlayEntry (non-modal) so right-clicks on other items still fire.
Future<T?> showNoteeMenuAt<T>(
  BuildContext context, {
  required Offset position,
  required List<NoteeMenuItem<T>> items,
  double maxWidth = 220,
}) {
  // Dismiss any currently open context menu.
  _activeMenuDismiss?.call();
  _activeMenuDismiss = null;

  late OverlayEntry barrierEntry;
  late OverlayEntry menuEntry;
  final completer = Completer<T?>();

  void dismiss([T? val]) {
    if (completer.isCompleted) return;
    _activeMenuDismiss = null;
    try { barrierEntry.remove(); } catch (_) {}
    try { menuEntry.remove(); } catch (_) {}
    completer.complete(val);
  }

  _activeMenuDismiss = () => dismiss(null);

  // Full-screen transparent barrier — absorbs left-clicks outside the menu
  // to dismiss; right-clicks pass through (GestureDetector.onTap is left only).
  barrierEntry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => dismiss(null),
      ),
    ),
  );

  menuEntry = OverlayEntry(
    builder: (ctx) {
      final screen = MediaQuery.sizeOf(ctx);
      final t = NoteeProvider.of(ctx).tokens;

      double left = position.dx;
      double top = position.dy;
      if (left + maxWidth > screen.width - 8) left = screen.width - maxWidth - 8;
      if (left < 8) left = 8;
      if (top > screen.height - 8) top = screen.height - 8;

      return Positioned(
        left: left,
        top: top,
        width: maxWidth,
        child: Material(
          color: Colors.transparent,
          // opaque GestureDetector absorbs left-clicks inside the menu
          // so the translucent barrier does NOT fire for intra-menu clicks.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {}, // absorb to prevent barrier dismiss
            child: NoteePopoverShell(
              tokens: t,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in items)
                    if (item.divider)
                      const _Divider()
                    else
                      _MenuRow(item: item, onTap: () => dismiss(item.value)),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  final overlay = Overlay.of(context);
  overlay.insert(barrierEntry);
  overlay.insert(menuEntry);

  return completer.future;
}

class NoteeMenuItem<T> {
  const NoteeMenuItem({
    required this.label,
    this.icon,
    this.value,
    this.danger = false,
    this.subtitle,
    this.divider = false,
  });
  /// Use [NoteeMenuItem.separator] for visual dividers between groups.
  const NoteeMenuItem.separator()
      : label = '',
        icon = null,
        value = null,
        danger = false,
        subtitle = null,
        divider = true;

  final String label;
  final Widget? icon;
  final T? value;
  final bool danger;
  final String? subtitle;
  final bool divider;
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.item, required this.onTap});
  final NoteeMenuItem<T> item;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final color = item.danger ? const Color(0xFFC62828) : t.ink;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          if (item.icon != null) ...[
            IconTheme(
                data: IconThemeData(color: color, size: 16),
                child: item.icon!),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: TextStyle(
                    fontFamily: 'Inter Tight',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: color,
                    height: 1.1,
                  ),
                ),
                if (item.subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle!,
                    style: TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 11,
                      color: t.inkDim,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(height: 0.5, color: t.rule),
    );
  }
}
