part of 'toolbar.dart';

// ── Width group ───────────────────────────────────────────────────────
// Tap → select. Tap active → stroke style. Long-press → edit that slot's value.
class _WidthGroup extends ConsumerStatefulWidget {
  const _WidthGroup({this.axis = Axis.horizontal});
  final Axis axis;
  @override
  ConsumerState<_WidthGroup> createState() => _WidthGroupState();
}

class _WidthGroupState extends ConsumerState<_WidthGroup> {
  // One key per slot for popovers.
  final _keys = List.generate(5, (_) => GlobalKey());
  int? _styleSlot; // null = closed; 0..4 = slot editor
  VoidCallback? _dismiss;

  @override
  void dispose() {
    _dismiss?.call();
    super.dispose();
  }

  void _openSettings(int slotIndex) {
    _dismiss?.call();
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _keys[slotIndex],
      maxWidth: 230,
      placement: toolbarPopoverPlacement(ref),
      builder: (ctx, dismiss) => _StrokeSettingsBody(
        slotIndex: slotIndex,
        dismiss: dismiss,
      ),
    );
    setState(() { _styleSlot = slotIndex; _dismiss = dismiss; });
  }

  void _close() {
    _dismiss?.call();
    if (mounted) setState(() { _styleSlot = null; _dismiss = null; });
  }

  @override
  Widget build(BuildContext context) {
    // Close any open width popover when the active tool changes.
    ref.listen<AppTool>(
      toolProvider.select((s) => s.activeTool),
      (_, __) { if (_dismiss != null) _close(); },
    );
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final selectedWidth = _activeWidth(s);
    final widths = _activePaletteWidths(s);
    int nearestIdx = 0;
    for (var i = 1; i < widths.length; i++) {
      if ((widths[i] - selectedWidth).abs() <
          (widths[nearestIdx] - selectedWidth).abs()) {
        nearestIdx = i;
      }
    }

    return Flex(
      direction: widget.axis,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widths.length; i++)
          KeyedSubtree(
            key: _keys[i],
            child: _WidthBtn(
              width: widths[i],
              lineStyle: s.activeTool == AppTool.pen
                  ? (i < s.penPaletteLineStyles.length
                      ? s.penPaletteLineStyles[i]
                      : 0)
                  : 0,
              active: i == nearestIdx,
              editing: _styleSlot == i,
              onTap: () {
                if (i == nearestIdx) {
                  _styleSlot == i ? _close() : _openSettings(i);
                } else {
                  if (_styleSlot != null) _close();
                  _setWidthForActive(s, ctl, widths[i]);
                  if (s.activeTool == AppTool.pen &&
                      i < s.penPaletteLineStyles.length) {
                    ctl.setPenLineStyle(s.penPaletteLineStyles[i]);
                  }
                }
              },
              onLongPress: () {
                _styleSlot == i ? _close() : _openSettings(i);
              },
            ),
          ),
      ],
    );
  }
}

// Combined stroke settings: style picker + palette slot width slider.
class _StrokeSettingsBody extends ConsumerStatefulWidget {
  const _StrokeSettingsBody({required this.slotIndex, required this.dismiss});
  final int slotIndex;
  final VoidCallback dismiss;
  @override
  ConsumerState<_StrokeSettingsBody> createState() => _StrokeSettingsBodyState();
}

class _StrokeSettingsBodyState extends ConsumerState<_StrokeSettingsBody> {
  late double _slotWidth;
  late TextEditingController _widthCtl;
  late FocusNode _widthFocus;

  static const _styles = <(int, String)>[
    (0, '단색'),
    (1, '파선'),
    (2, '점선'),
  ];

  @override
  void initState() {
    super.initState();
    _slotWidth = _activePaletteWidths(ref.read(toolProvider))[widget.slotIndex];
    _widthCtl = TextEditingController(text: _formatWidth(_slotWidth));
    _widthFocus = FocusNode();
    _widthFocus.addListener(() {
      if (!_widthFocus.hasFocus) _commitWidth();
    });
  }

  @override
  void dispose() {
    _widthCtl.dispose();
    _widthFocus.dispose();
    super.dispose();
  }

  static String _formatWidth(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('00')
        ? s.substring(0, s.length - 3)
        : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
  }

  void _commitWidth() {
    final raw = _widthCtl.text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(raw);
    final s = ref.read(toolProvider);
    if (parsed == null) {
      _widthCtl.text = _formatWidth(_slotWidth);
      return;
    }
    final clamped =
        parsed.clamp(_sliderMinFor(s.activeTool), _sliderMaxFor(s.activeTool));
    setState(() => _slotWidth = clamped);
    _widthCtl.text = _formatWidth(clamped);
    final ctl = ref.read(toolProvider.notifier);
    ctl.setPaletteWidth(widget.slotIndex, clamped);
    _setWidthForActive(s, ctl, clamped);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final t = NoteeProvider.of(context).tokens;
    final mm = (_slotWidth * 0.353).toStringAsFixed(1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Text('획 설정',
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                )),
            const Spacer(),
            GestureDetector(
              onTap: widget.dismiss,
              child: Icon(Icons.close, size: 14, color: t.inkFaint),
            ),
          ]),
        ),
        if (s.activeTool == AppTool.pen) ...[
          Row(children: [
            for (final entry in _styles)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _StrokeStyleTile(
                    style: entry.$1,
                    label: entry.$2,
                    selected: (widget.slotIndex < s.penPaletteLineStyles.length
                            ? s.penPaletteLineStyles[widget.slotIndex]
                            : 0) ==
                        entry.$1,
                    onTap: () => ctl.setPenPaletteLineStyle(
                        widget.slotIndex, entry.$1),
                  ),
                ),
              ),
          ]),
          if ((widget.slotIndex < s.penPaletteLineStyles.length
                  ? s.penPaletteLineStyles[widget.slotIndex]
                  : 0) !=
              0) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Text('간격',
                    style: TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 11,
                      color: t.inkDim,
                    )),
                const Spacer(),
                Text('${s.penDashGap.toStringAsFixed(1)}×',
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      color: t.inkFaint,
                    )),
              ]),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: t.accent,
                inactiveTrackColor: t.rule,
                thumbColor: t.accent,
                trackHeight: 3,
              ),
              child: Slider(
                min: 0.5,
                max: 5.0,
                value: s.penDashGap.clamp(0.5, 5.0),
                onChanged: (v) => ctl.setPenDashGap(v),
              ),
            ),
          ],
          const SizedBox(height: 14),
        ],
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Text('두께',
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 11,
                  color: t.inkDim,
                )),
            const Spacer(),
            Text('$mm mm',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  color: t.inkFaint,
                )),
          ]),
        ),
        Row(children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: t.accent,
                inactiveTrackColor: t.rule,
                thumbColor: t.accent,
                trackHeight: 3,
              ),
              child: Slider(
                min: _sliderMinFor(s.activeTool),
                max: _sliderMaxFor(s.activeTool),
                value: _slotWidth.clamp(
                  _sliderMinFor(s.activeTool),
                  _sliderMaxFor(s.activeTool),
                ),
                onChanged: (v) {
                  setState(() => _slotWidth = v);
                  if (!_widthFocus.hasFocus) {
                    _widthCtl.text = _formatWidth(v);
                  }
                  ctl.setPaletteWidth(widget.slotIndex, v);
                  _setWidthForActive(s, ctl, v);
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            height: 30,
            child: TextField(
              controller: _widthCtl,
              focusNode: _widthFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: t.ink,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                suffixText: 'pt',
                suffixStyle: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9,
                  color: t.inkFaint,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: t.tbBorder, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: t.accent, width: 1),
                ),
              ),
              onSubmitted: (_) => _commitWidth(),
              onEditingComplete: _commitWidth,
            ),
          ),
        ]),
      ],
    );
  }
}

class _StrokeStyleTile extends StatelessWidget {
  const _StrokeStyleTile({
    required this.style,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final int style;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? t.accentSoft : t.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? t.accent : t.tbBorder,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Column(children: [
          SizedBox(
            width: 36,
            height: 14,
            child: CustomPaint(
              painter: _StrokeStylePainter(
                style: style,
                color: selected ? t.accent : t.ink,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter Tight',
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? t.accent : t.ink,
              height: 1.0,
            ),
          ),
        ]),
      ),
    );
  }
}

class _StrokeStylePainter extends CustomPainter {
  _StrokeStylePainter({required this.style, required this.color});
  final int style;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (style == 0) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    } else if (style == 1) {
      const dash = 5.0, gap = 3.0;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + dash).clamp(0, size.width), y),
          paint,
        );
        x += dash + gap;
      }
    } else {
      const step = 4.0;
      var x = 1.0;
      final dotPaint = Paint()..color = color;
      while (x < size.width) {
        canvas.drawCircle(Offset(x, y), 1.2, dotPaint);
        x += step;
      }
    }
  }

  @override
  bool shouldRepaint(_StrokeStylePainter old) =>
      old.style != style || old.color != color;
}

class _WidthBtn extends StatelessWidget {
  const _WidthBtn({
    required this.width,
    required this.active,
    required this.onTap,
    this.lineStyle = 0,
    this.editing = false,
    this.onLongPress,
  });
  final double width;
  final int lineStyle;
  final bool active;
  final bool editing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static const _barColor = Color(0xFF111827);
  static const _dur = Duration(milliseconds: 140);

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final borderColor = editing
        ? t.accent
        : (active ? t.accent.withValues(alpha: 0.6) : Colors.transparent);
    final barH = (width * 1.2 + 0.6).clamp(1.5, 10.0);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: _dur,
        curve: Curves.easeOut,
        width: 22,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: (active || editing) ? t.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: borderColor, width: editing ? 1.0 : 0.5),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 16,
          height: barH,
          child: CustomPaint(
            painter: _WidthPreviewPainter(
              lineStyle: lineStyle,
              color: _barColor,
              strokeWidth: barH,
            ),
          ),
        ),
      ),
    );
  }
}

class _WidthPreviewPainter extends CustomPainter {
  _WidthPreviewPainter({
    required this.lineStyle,
    required this.color,
    required this.strokeWidth,
  });
  final int lineStyle;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (lineStyle == 0) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(size.height / 2),
      );
      canvas.drawRRect(rect, Paint()..color = color);
    } else if (lineStyle == 1) {
      const dash = 5.0, gap = 3.0;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + dash).clamp(0, size.width), y),
          paint,
        );
        x += dash + gap;
      }
    } else {
      const step = 4.0;
      var x = 1.0;
      final dotPaint = Paint()..color = color;
      while (x < size.width) {
        canvas.drawCircle(Offset(x, y), strokeWidth / 2, dotPaint);
        x += step;
      }
    }
  }

  @override
  bool shouldRepaint(_WidthPreviewPainter old) =>
      old.lineStyle != lineStyle || old.color != color || old.strokeWidth != strokeWidth;
}

// ── Color group ───────────────────────────────────────────────────────
// Shows 6 palette swatches. Tap → apply. Long-press → edit that slot's color.
class _ColorGroup extends ConsumerStatefulWidget {
  const _ColorGroup({this.axis = Axis.horizontal});
  final Axis axis;
  @override
  ConsumerState<_ColorGroup> createState() => _ColorGroupState();
}

class _ColorGroupState extends ConsumerState<_ColorGroup> {
  // One anchor key per slot so the popover can anchor to the right swatch.
  final _keys = List.generate(6, (_) => GlobalKey());
  int? _editingSlot;
  VoidCallback? _dismiss;

  @override
  void dispose() {
    _dismiss?.call();
    super.dispose();
  }

  void _openEditor(int slotIndex) {
    _dismiss?.call();
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _keys[slotIndex],
      maxWidth: 260,
      placement: toolbarPopoverPlacement(ref),
      builder: (ctx, dismiss) => _SlotColorEditor(
        slotIndex: slotIndex,
        dismiss: dismiss,
      ),
    );
    setState(() { _editingSlot = slotIndex; _dismiss = dismiss; });
  }

  void _close() {
    _dismiss?.call();
    if (mounted) setState(() { _editingSlot = null; _dismiss = null; });
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    // Close any open color popover when the active tool changes.
    ref.listen<AppTool>(
      toolProvider.select((s) => s.activeTool),
      (_, __) { if (_dismiss != null) _close(); },
    );
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final activeArgb = _activeColor(s);
    final isDark = t.brightness == Brightness.dark;
    final palette = _activePaletteColors(s, isDark: isDark);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Flex(
        direction: widget.axis,
        mainAxisSize: MainAxisSize.min,
        children: [
        for (var i = 0; i < palette.length; i++)
          KeyedSubtree(
            key: _keys[i],
            child: GestureDetector(
              onTap: () {
                if (activeArgb == palette[i]) {
                  if (_editingSlot == i) { _close(); } else { _openEditor(i); }
                } else {
                  _setColorForActive(s, ctl, palette[i]);
                  if (_editingSlot != null) _close();
                }
              },
              onLongPress: () {
                if (_editingSlot == i) { _close(); } else { _openEditor(i); }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                width: 15,
                height: 15,
                margin: widget.axis == Axis.horizontal
                    ? const EdgeInsets.symmetric(horizontal: 2)
                    : const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: Color(palette[i]),
                  shape: BoxShape.circle,
                  boxShadow: [
                    if (activeArgb == palette[i])
                      BoxShadow(color: t.page, blurRadius: 0, spreadRadius: 1.5),
                    if (activeArgb == palette[i])
                      BoxShadow(color: t.accent, blurRadius: 0, spreadRadius: 2.5),
                    if (_editingSlot == i)
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
        ]),
    );
  }
}

// ── Slot color editor (HSV picker for editing a palette slot) ─────────
class _SlotColorEditor extends ConsumerStatefulWidget {
  const _SlotColorEditor({
    required this.slotIndex,
    required this.dismiss,
    this.forFill = false,
  });
  final bool forFill;
  final int slotIndex;
  final VoidCallback dismiss;
  @override
  ConsumerState<_SlotColorEditor> createState() => _SlotColorEditorState();
}

class _SlotColorEditorState extends ConsumerState<_SlotColorEditor> {
  late TextEditingController _hexCtl;
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    final ts = ref.read(toolProvider);
    final argb = widget.forFill
        ? ts.shapeFillPaletteColors[widget.slotIndex]
        : _activePaletteColors(ts)[widget.slotIndex];
    _hsv = HSVColor.fromColor(Color(argb));
    _hexCtl = TextEditingController(text: _hex(argb));
  }

  @override
  void dispose() {
    _hexCtl.dispose();
    super.dispose();
  }

  static String _hex(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _applyHsv(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final argb = hsv.toColor().toARGB32();
    _hexCtl.text = _hex(argb);
    final ctl = ref.read(toolProvider.notifier);
    if (widget.forFill) {
      ctl.setShapeFillPaletteColor(widget.slotIndex, argb);
      ctl.setShapeFillColor(argb);
    } else {
      ctl.setPaletteColor(widget.slotIndex, argb);
    }
  }

  void _applyHex(String hex) {
    final clean = hex.replaceAll('#', '').toUpperCase();
    if (clean.length != 6) return;
    final v = int.tryParse(clean, radix: 16);
    if (v == null) return;
    final alpha = (_hsv.alpha * 255).round() & 0xff;
    final argb = (alpha << 24) | v;
    setState(() => _hsv = HSVColor.fromColor(Color(argb)).withAlpha(_hsv.alpha));
    final ctl = ref.read(toolProvider.notifier);
    if (widget.forFill) {
      ctl.setShapeFillPaletteColor(widget.slotIndex, argb);
      ctl.setShapeFillColor(argb);
    } else {
      ctl.setPaletteColor(widget.slotIndex, argb);
    }
  }

  void _onSV(Offset pos, double w, double h) {
    final sat = (pos.dx / w).clamp(0.0, 1.0);
    final val = (1 - pos.dy / h).clamp(0.0, 1.0);
    _applyHsv(_hsv.withSaturation(sat).withValue(val));
  }

  void _onHue(double x, double w) =>
      _applyHsv(_hsv.withHue((x / w * 360).clamp(0.0, 360.0)));

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final hueColor = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Text(
              '색상 변경',
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: widget.dismiss,
              child: Icon(Icons.close, size: 14, color: t.inkFaint),
            ),
          ]),
        ),
        AspectRatio(
          aspectRatio: 1.6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LayoutBuilder(builder: (_, c) {
              final w = c.maxWidth, h = c.maxHeight;
              return GestureDetector(
                onPanDown: (d) => _onSV(d.localPosition, w, h),
                onPanUpdate: (d) => _onSV(d.localPosition, w, h),
                child: Stack(children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [Colors.white, hueColor]),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (_hsv.saturation * w - 6).clamp(0, w - 12),
                    top: ((1 - _hsv.value) * h - 6).clamp(0, h - 12),
                    child: Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ]),
              );
            }),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 14,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: LayoutBuilder(builder: (_, c) {
              final w = c.maxWidth;
              return GestureDetector(
                onPanDown: (d) => _onHue(d.localPosition.dx, w),
                onPanUpdate: (d) => _onHue(d.localPosition.dx, w),
                child: Stack(children: [
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          Color(0xFFFF0000), Color(0xFFFFFF00),
                          Color(0xFF00FF00), Color(0xFF00FFFF),
                          Color(0xFF0000FF), Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ]),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (_hsv.hue / 360 * w - 5).clamp(0, w - 10),
                    top: -1,
                    child: Container(
                      width: 10, height: 16,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.25),
                          width: 0.5,
                        ),
                      ),
                    ),
                  ),
                ]),
              );
            }),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Text('HEX',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                color: t.inkFaint,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 26,
              child: TextField(
                controller: _hexCtl,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: t.ink,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  filled: true,
                  fillColor: t.bg,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: t.tbBorder, width: 0.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: t.accent, width: 1),
                  ),
                ),
                onSubmitted: _applyHex,
                onChanged: (v) { if (v.length == 6) _applyHex(v); },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
              color: _hsv.toColor(),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.25),
                width: 0.5,
              ),
            ),
          ),
        ]),
        if (ref.watch(toolProvider).activeTool != AppTool.tape) ...[
        const SizedBox(height: 10),
        Row(children: [
          Text('OPACITY',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                color: t.inkFaint,
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(width: 6),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: t.accent,
                inactiveTrackColor: t.rule,
                thumbColor: t.accent,
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                min: 0.0,
                max: 1.0,
                value: _hsv.alpha.clamp(0.0, 1.0),
                onChanged: (v) => _applyHsv(_hsv.withAlpha(v)),
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${(_hsv.alpha * 100).round()}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                color: t.inkFaint,
              ),
            ),
          ),
        ]),
        ],
      ],
    );
  }
}
