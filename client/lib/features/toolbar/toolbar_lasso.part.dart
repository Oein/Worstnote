part of 'toolbar.dart';

// ── Lasso button (lasso ↔ rectSelect toggle) ─────────────────────────
class _LassoButton extends ConsumerWidget {
  const _LassoButton();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final active =
        s.activeTool == AppTool.lasso || s.activeTool == AppTool.rectSelect;
    // Source of truth for the icon is the active tool when this button is
    // active (so the L-key toggle, which only changes activeTool, updates
    // the glyph). When inactive, fall back to the persisted preference.
    final isRect = active
        ? s.activeTool == AppTool.rectSelect
        : s.lassoIsRect;

    void toggle() {
      final newRect = !isRect;
      ctl.setLassoRect(newRect);
      if (active) ctl.setTool(newRect ? AppTool.rectSelect : AppTool.lasso);
    }

    return _GlyphButton(
      active: active,
      onTap: () {
        if (active) {
          toggle();
        } else {
          ctl.setTool(isRect ? AppTool.rectSelect : AppTool.lasso);
        }
      },
      onLongPress: toggle,
      child: isRect
          ? SizedBox(
              width: 15, height: 15,
              child: CustomPaint(
                painter: _DashedRectGlyphPainter(
                  color: active ? t.accent : t.ink,
                ),
              ),
            )
          : NoteeIconWidget(NoteeIcon.lasso, size: 15,
              color: active ? t.accent : t.ink),
    );
  }
}

/// Dashed rectangle glyph for the rectSelect (lasso → rect) mode button.
class _DashedRectGlyphPainter extends CustomPainter {
  _DashedRectGlyphPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final r = Rect.fromLTWH(1.5, 1.5, size.width - 3, size.height - 3);
    const dashLen = 2.2;
    const gap = 1.6;
    void dashLine(Offset a, Offset b) {
      final delta = b - a;
      final len = delta.distance;
      if (len <= 0) return;
      final dir = delta / len;
      var pos = 0.0;
      var draw = true;
      while (pos < len) {
        final seg = draw ? dashLen : gap;
        final end = (pos + seg).clamp(0.0, len);
        if (draw) canvas.drawLine(a + dir * pos, a + dir * end, paint);
        pos += seg;
        draw = !draw;
      }
    }
    dashLine(r.topLeft, r.topRight);
    dashLine(r.topRight, r.bottomRight);
    dashLine(r.bottomRight, r.bottomLeft);
    dashLine(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(covariant _DashedRectGlyphPainter old) =>
      old.color != color;
}
