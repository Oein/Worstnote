part of 'toolbar.dart';

// ── Pen button (with type + smoothing passthrough popover) ──────────
// Uses a non-modal OverlayEntry so the canvas remains drawable while the
// panel is open. Tap the pen button again (when active) to toggle it.
class _PenButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PenButton> createState() => _PenButtonState();
}

class _PenButtonState extends ConsumerState<_PenButton> {
  final _key = GlobalKey();
  VoidCallback? _dismissPanel;
  bool _panelOpen = false;

  @override
  void dispose() {
    _dismissPanel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final active =
        ref.watch(toolProvider.select((s) => s.activeTool == AppTool.pen));

    ref.listen(toolProvider.select((s) => s.activeTool), (_, next) {
      if (next != AppTool.pen && _panelOpen) _closePanel();
    });

    return _GlyphButton(
      anchorKey: _key,
      active: active,
      onTap: () {
        if (active) {
          _panelOpen ? _closePanel() : _openPanel();
        } else {
          ref.read(toolProvider.notifier).setTool(AppTool.pen);
        }
      },
      onLongPress: _openPanel,
      child: NoteeIconWidget(NoteeIcon.pen,
          size: 15, color: active ? t.accent : t.ink),
    );
  }

  void _openPanel() {
    if (_panelOpen) return;
    ref.read(toolProvider.notifier).setTool(AppTool.pen);
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _key,
      maxWidth: 280,
      placement: toolbarPopoverPlacement(ref),
      onDismiss: () {
        if (!mounted) return;
        setState(() { _dismissPanel = null; _panelOpen = false; });
      },
      builder: (ctx, dismiss) => _PenPopoverBody(dismiss: dismiss),
    );
    setState(() {
      _dismissPanel = dismiss;
      _panelOpen = true;
    });
  }

  void _closePanel() {
    _dismissPanel?.call();
    if (mounted) setState(() { _dismissPanel = null; _panelOpen = false; });
  }
}

class _PenPopoverBody extends ConsumerStatefulWidget {
  const _PenPopoverBody({required this.dismiss});
  final VoidCallback dismiss;
  @override
  ConsumerState<_PenPopoverBody> createState() => _PenPopoverBodyState();
}

class _PenPopoverBodyState extends ConsumerState<_PenPopoverBody> {
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final t = NoteeProvider.of(context).tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Text('PEN STYLE', style: noteeSectionEyebrow(t)),
            const Spacer(),
            GestureDetector(
              onTap: widget.dismiss,
              child: Icon(Icons.close, size: 14, color: t.inkFaint),
            ),
          ]),
        ),
        Row(children: [
          for (final pt in PenType.values)
            Expanded(child: _PenTypeTile(type: pt, current: s.penType)),
        ]),
        const SizedBox(height: 14),
        Text('SMOOTHING', style: noteeSectionEyebrow(t)),
        const SizedBox(height: 8),
        Row(children: [
          for (final algo in PenSmoothingAlgorithm.values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: GestureDetector(
                  onTap: () => ctl.setPenSmoothingAlgo(algo),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: s.penSmoothingAlgo == algo ? t.accent : t.rule,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      algo.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Inter Tight',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: s.penSmoothingAlgo == algo ? Colors.white : t.inkDim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        if (s.penSmoothingAlgo == PenSmoothingAlgorithm.leash) ...[
          _SmoothingSliderRow(
            label: 'Strength',
            value: s.penLeashStrength,
            onChanged: ctl.setPenLeashStrength,
            max: 0.25,
          ),
        ] else ...[
          _SmoothingSliderRow(
            label: 'Smoothing',
            value: s.penOneEuroSmoothing,
            onChanged: ctl.setPenOneEuroSmoothing,
          ),
          const SizedBox(height: 6),
          _SmoothingSliderRow(
            label: 'Speed',
            value: s.penOneEuroBeta,
            onChanged: ctl.setPenOneEuroBeta,
          ),
        ],
      ],
    );
  }
}

class _PenTypeTile extends ConsumerWidget {
  const _PenTypeTile({required this.type, required this.current});
  final PenType type;
  final PenType current;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final selected = type == current;
    final label = switch (type) {
      PenType.ballpoint => 'Ballpoint',
      PenType.fountain => 'Fountain',
      PenType.brush => 'Brush',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: () => ref.read(toolProvider.notifier).setPenType(type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? t.accentSoft : t.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? t.accent : t.tbBorder,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Column(children: [
            NoteeIconWidget(
              type == PenType.brush
                  ? NoteeIcon.highlight
                  : type == PenType.fountain
                      ? NoteeIcon.pen
                      : NoteeIcon.pen,
              size: 18,
              color: selected ? t.accent : t.ink,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? t.accent : t.ink,
                height: 1.0,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SmoothingSliderRow extends StatefulWidget {
  const _SmoothingSliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
  });
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;

  @override
  State<_SmoothingSliderRow> createState() => _SmoothingSliderRowState();
}

class _SmoothingSliderRowState extends State<_SmoothingSliderRow> {
  late final TextEditingController _ctl;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.value.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(_SmoothingSliderRow old) {
    super.didUpdateWidget(old);
    if (!_editing && old.value != widget.value) {
      _ctl.text = widget.value.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _commit(String text) {
    final v = double.tryParse(text);
    if (v != null) {
      widget.onChanged(v.clamp(widget.min, widget.max));
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final clamped = widget.value.clamp(widget.min, widget.max);
    if (!_editing) _ctl.text = clamped.toStringAsFixed(2);
    return Row(children: [
      SizedBox(
        width: 64,
        child: Text(
          widget.label,
          style: TextStyle(
            fontFamily: 'Inter Tight',
            fontSize: 11,
            color: t.inkDim,
          ),
        ),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: t.accent,
            inactiveTrackColor: t.rule,
            thumbColor: t.accent,
            overlayColor: t.accent.withValues(alpha: 0.15),
          ),
          child: Slider(
            value: clamped,
            min: widget.min,
            max: widget.max,
            onChanged: (v) {
              widget.onChanged(v);
              if (!_editing) _ctl.text = v.toStringAsFixed(2);
            },
          ),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(
        width: 44,
        child: TextField(
          controller: _ctl,
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
                const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: t.tbBorder, width: 0.5),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: t.tbBorder, width: 0.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: t.accent, width: 1),
            ),
          ),
          onTap: () => setState(() => _editing = true),
          onSubmitted: _commit,
          onEditingComplete: () => _commit(_ctl.text),
        ),
      ),
    ]);
  }
}
