part of 'toolbar.dart';

// ── Shape button — persistent floating bar, like the text tool ────────
class _ShapeButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ShapeButton> createState() => _ShapeButtonState();
}

class _ShapeButtonState extends ConsumerState<_ShapeButton> {
  final _key = GlobalKey();
  VoidCallback? _dismiss;
  bool _barOpen = false;

  static bool _isShape(AppTool t) =>
      t == AppTool.shapeRect ||
      t == AppTool.shapeEllipse ||
      t == AppTool.shapeTriangle ||
      t == AppTool.shapeDiamond ||
      t == AppTool.shapeArrow ||
      t == AppTool.shapeLine;

  @override
  void dispose() {
    _dismiss?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final active = _isShape(s.activeTool);

    ref.listen(toolProvider.select((s) => s.activeTool), (_, next) {
      if (_isShape(next) && !_barOpen) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) { if (mounted) _openBar(); });
      } else if (!_isShape(next) && _barOpen) {
        _closeBar();
      }
    });

    return _GlyphButton(
      anchorKey: _key,
      active: active,
      onTap: () {
        if (active) {
          if (!_barOpen) _openBar();
        } else {
          ctl.setTool(s.lastShapeVariant);
        }
      },
      child: SizedBox(
        width: 16, height: 16,
        child: CustomPaint(
          painter: _ShapeToolGlyphPainter(
            color: active ? t.accent : t.ink,
          ),
        ),
      ),
    );
  }

  void _openBar() {
    if (_barOpen || !mounted) return;
    final vertical = toolbarIsVerticalDock(ref);
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _key,
      placement: toolbarPopoverPlacement(ref),
      onDismiss: () {
        // Popover closed externally (outside tap, or replaced by another
        // passthrough popover). Reset our tracking so the next tap on the
        // shape button reopens it.
        if (!mounted) return;
        setState(() { _dismiss = null; _barOpen = false; });
      },
      builder: (ctx, dismiss) =>
          _ShapeFormatBarBody(dismiss: dismiss, vertical: vertical),
    );
    setState(() { _dismiss = dismiss; _barOpen = true; });
  }

  void _closeBar() {
    _dismiss?.call();
    if (mounted) setState(() { _dismiss = null; _barOpen = false; });
  }
}

// ── Shape format bar body ──────────────────────────────────────────────
class _ShapeFormatBarBody extends ConsumerStatefulWidget {
  const _ShapeFormatBarBody({required this.dismiss, this.vertical = false});
  final VoidCallback dismiss;
  final bool vertical;
  @override
  ConsumerState<_ShapeFormatBarBody> createState() =>
      _ShapeFormatBarBodyState();
}

class _ShapeFormatBarBodyState extends ConsumerState<_ShapeFormatBarBody> {
  final _fillKeys = List.generate(6, (_) => GlobalKey());
  int? _editingFillSlot;
  VoidCallback? _fillDismiss;

  @override
  void dispose() {
    _fillDismiss?.call();
    super.dispose();
  }

  void _openFillEditor(int slotIndex) {
    _fillDismiss?.call();
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _fillKeys[slotIndex],
      maxWidth: 260,
      replacesActive: false, // nested under the shape modal
      builder: (ctx, dismiss) => _SlotColorEditor(
        slotIndex: slotIndex,
        dismiss: dismiss,
        forFill: true,
      ),
    );
    setState(() { _editingFillSlot = slotIndex; _fillDismiss = dismiss; });
  }

  void _closeFillEditor() {
    _fillDismiss?.call();
    if (mounted) setState(() { _editingFillSlot = null; _fillDismiss = null; });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final t = NoteeProvider.of(context).tokens;
    const shapes = [
      AppTool.shapeRect,
      AppTool.shapeEllipse,
      AppTool.shapeTriangle,
      AppTool.shapeDiamond,
      AppTool.shapeArrow,
      AppTool.shapeLine,
    ];

    Widget shapeBtn(AppTool app) {
      final sel = s.activeTool == app;
      return Tooltip(
        message: _shapeLabel(app),
        child: GestureDetector(
          onTap: () => ctl.setTool(app),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 26, height: 26,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: sel ? t.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: sel ? t.accent.withValues(alpha: 0.6) : Colors.transparent,
                width: 0.5,
              ),
            ),
            alignment: Alignment.center,
            child: SizedBox(
              width: 15, height: 15,
              child: CustomPaint(
                painter: _ShapeGlyphPainter(
                  app: app,
                  color: sel ? t.accent : t.ink,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final vertical = widget.vertical;
    Widget divider() => vertical
        ? Container(
            height: 0.5,
            width: 26,
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: t.rule,
          )
        : Container(
            width: 0.5,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: t.rule,
          );

    final fillArgb = s.shapeFillColorArgb;

    return SingleChildScrollView(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      child: Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        children: [
        for (final app in shapes) shapeBtn(app),
        divider(),
        Tooltip(
          message: 'Fill',
          child: GestureDetector(
            onTap: () => ctl.setShapeFilled(!s.shapeFilled),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              width: 26, height: 26,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: s.shapeFilled ? t.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: s.shapeFilled
                      ? t.accent.withValues(alpha: 0.6)
                      : Colors.transparent,
                  width: 0.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.format_color_fill_rounded,
                  size: 15, color: s.shapeFilled ? t.accent : t.ink),
            ),
          ),
        ),
        if (s.shapeFilled) ...[
          divider(),
          for (var i = 0; i < s.shapeFillPaletteColors.length; i++)
            KeyedSubtree(
              key: _fillKeys[i],
              child: GestureDetector(
                onTap: () {
                  final argb = s.shapeFillPaletteColors[i];
                  if (fillArgb == argb) {
                    if (_editingFillSlot == i) {
                      _closeFillEditor();
                    } else {
                      _openFillEditor(i);
                    }
                  } else {
                    ctl.setShapeFillColor(argb);
                    if (_editingFillSlot != null) _closeFillEditor();
                  }
                },
                onLongPress: () {
                  if (_editingFillSlot == i) {
                    _closeFillEditor();
                  } else {
                    _openFillEditor(i);
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  width: 15, height: 15,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: Color(s.shapeFillPaletteColors[i]),
                    shape: BoxShape.circle,
                    boxShadow: [
                      if (fillArgb == s.shapeFillPaletteColors[i])
                        BoxShadow(color: t.page, blurRadius: 0, spreadRadius: 1.5),
                      if (fillArgb == s.shapeFillPaletteColors[i])
                        BoxShadow(color: t.accent, blurRadius: 0, spreadRadius: 2.5),
                      if (_editingFillSlot == i)
                        BoxShadow(color: t.accent.withValues(alpha: 0.5), blurRadius: 0, spreadRadius: 2.5),
                    ],
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ]),
    );
  }

  static String _shapeLabel(AppTool app) {
    switch (app) {
      case AppTool.shapeRect: return '직사각형';
      case AppTool.shapeEllipse: return '타원';
      case AppTool.shapeTriangle: return '삼각형';
      case AppTool.shapeDiamond: return '다이아몬드';
      case AppTool.shapeArrow: return '화살표';
      case AppTool.shapeLine: return '선';
      default: return '';
    }
  }
}

class _ShapeGlyphPainter extends CustomPainter {
  _ShapeGlyphPainter({required this.app, required this.color});
  final AppTool app;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    switch (app) {
      case AppTool.shapeRect:
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)), paint);
      case AppTool.shapeEllipse:
        canvas.drawOval(r, paint);
      case AppTool.shapeTriangle:
        final p = Path()
          ..moveTo(r.center.dx, r.top)
          ..lineTo(r.right, r.bottom)
          ..lineTo(r.left, r.bottom)
          ..close();
        canvas.drawPath(p, paint);
      case AppTool.shapeDiamond:
        final p = Path()
          ..moveTo(r.center.dx, r.top)
          ..lineTo(r.right, r.center.dy)
          ..lineTo(r.center.dx, r.bottom)
          ..lineTo(r.left, r.center.dy)
          ..close();
        canvas.drawPath(p, paint);
      case AppTool.shapeArrow:
        final tail = Offset(r.left + r.width * 0.1, r.bottom - r.height * 0.1);
        final head = Offset(r.right - r.width * 0.1, r.top + r.height * 0.1);
        final dx = head.dx - tail.dx;
        final dy = head.dy - tail.dy;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len >= 1) {
          final ux = dx / len;
          final uy = dy / len;
          final hl = len * 0.28;
          final hw = hl * 0.55;
          final bx = head.dx - ux * hl;
          final by = head.dy - uy * hl;
          canvas.drawLine(tail, Offset(bx, by), paint);
          final fp = Paint()
            ..color = paint.color
            ..style = PaintingStyle.fill
            ..isAntiAlias = true;
          canvas.drawPath(
            Path()
              ..moveTo(head.dx, head.dy)
              ..lineTo(bx + (-uy * hw), by + (ux * hw))
              ..lineTo(bx - (-uy * hw), by - (ux * hw))
              ..close(),
            fp,
          );
        }
      case AppTool.shapeLine:
        canvas.drawLine(
          Offset(r.left + r.width * 0.1, r.bottom - r.height * 0.1),
          Offset(r.right - r.width * 0.1, r.top + r.height * 0.1),
          paint,
        );
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ShapeGlyphPainter old) =>
      old.app != app || old.color != color;
}

/// Toolbar shape button glyph: rounded square + triangle + circle — signals
/// "shape primitives".
class _ShapeToolGlyphPainter extends CustomPainter {
  _ShapeToolGlyphPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;

    final sq = Rect.fromLTWH(w * 0.38, h * 0.08, w * 0.50, h * 0.50);
    canvas.drawRRect(
      RRect.fromRectAndRadius(sq, const Radius.circular(2)),
      stroke,
    );

    final tri = Path()
      ..moveTo(w * 0.38, h * 0.92)
      ..lineTo(w * 0.82, h * 0.92)
      ..lineTo(w * 0.60, h * 0.50)
      ..close();
    canvas.drawPath(tri, stroke);

    canvas.drawCircle(Offset(w * 0.22, h * 0.52), w * 0.18, stroke);
  }

  @override
  bool shouldRepaint(covariant _ShapeToolGlyphPainter old) => old.color != color;
}
