part of 'toolbar.dart';

// ── Eraser button (with 3-variant popover) ───────────────────────────
class _EraserButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_EraserButton> createState() => _EraserButtonState();
}

class _EraserButtonState extends ConsumerState<_EraserButton> {
  final _key = GlobalKey();

  bool _isAnyEraserActive(ToolState s) =>
      s.activeTool == AppTool.eraserArea ||
      s.activeTool == AppTool.eraserStroke;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final s = ref.watch(toolProvider);
    final active = _isAnyEraserActive(s);
    return _GlyphButton(
      anchorKey: _key,
      active: active,
      onTap: () {
        if (active) {
          _openPopover();
        } else {
          ref.read(toolProvider.notifier).setTool(s.lastEraserVariant);
        }
      },
      onLongPress: _openPopover,
      child: NoteeIconWidget(NoteeIcon.eraser,
          size: 15, color: active ? t.accent : t.ink),
    );
  }

  void _openPopover() {
    showNoteePopover<void>(
      context,
      anchorKey: _key,
      maxWidth: 320,
      placement: toolbarPopoverPlacement(ref),
      builder: (ctx) => const _EraserVariantPopover(),
    );
  }
}

// Inline eraser-area radius slider shown in the toolbar (replaces width+color groups).
class _EraserAreaSlider extends ConsumerStatefulWidget {
  const _EraserAreaSlider();
  @override
  ConsumerState<_EraserAreaSlider> createState() => _EraserAreaSliderState();
}

class _EraserAreaSliderState extends ConsumerState<_EraserAreaSlider> {
  late final TextEditingController _input;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    final r = ref.read(toolProvider).eraserAreaRadius;
    _input = TextEditingController(text: r.toStringAsFixed(1));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _commit(String text) {
    final v = double.tryParse(text);
    if (v != null && v > 0) {
      ref.read(toolProvider.notifier).setEraserAreaRadius(v);
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final radius = ref.watch(toolProvider.select((s) => s.eraserAreaRadius));
    final ctl = ref.read(toolProvider.notifier);

    if (!_editing) {
      _input.text = radius.toStringAsFixed(1);
    }

    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.tbBorder, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
        Text('SIZE', style: noteeSectionEyebrow(t)),
        const SizedBox(width: 4),
        SizedBox(
          width: 120,
          height: 32,
          child: Slider(
            min: 0.1,
            max: 20.0,
            divisions: 199,
            value: radius.clamp(0.1, 20.0),
            onChanged: (v) {
              ctl.setEraserAreaRadius(v);
              _input.text = v.toStringAsFixed(1);
            },
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: TextField(
            controller: _input,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: t.ink,
            ),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
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
            onEditingComplete: () => _commit(_input.text),
          ),
        ),
      ]),
    );
  }
}

class _EraserVariantPopover extends ConsumerWidget {
  const _EraserVariantPopover();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('ERASER TYPE', style: noteeSectionEyebrow(t)),
        ),
        Row(children: [
          Expanded(
            child: _EraserVariantTile(
              app: AppTool.eraserArea,
              icon: NoteeIcon.eraser,
              label: 'Standard',
              subtitle: 'Adjustable disc',
              current: s.activeTool,
              onTap: () => ctl.setTool(AppTool.eraserArea),
            ),
          ),
          Expanded(
            child: _EraserVariantTile(
              app: AppTool.eraserStroke,
              icon: NoteeIcon.eraser,
              label: 'Stroke',
              subtitle: 'Whole stroke',
              current: s.activeTool,
              onTap: () => ctl.setTool(AppTool.eraserStroke),
            ),
          ),
        ]),
        if (s.activeTool == AppTool.eraserArea) ...[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Text('SIZE', style: noteeSectionEyebrow(t)),
              const Spacer(),
              Text('${s.eraserAreaRadius.toStringAsFixed(1)} pt',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: t.inkFaint,
                  )),
            ]),
          ),
          Slider(
            min: 0.1,
            max: 20.0,
            divisions: 199,
            value: s.eraserAreaRadius.clamp(0.1, 20.0),
            onChanged: ctl.setEraserAreaRadius,
          ),
        ],
      ],
    );
  }
}

class _EraserVariantTile extends StatelessWidget {
  const _EraserVariantTile({
    required this.app,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.current,
    required this.onTap,
  });
  final AppTool app;
  final NoteeIcon icon;
  final String label;
  final String subtitle;
  final AppTool current;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final selected = app == current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? t.accentSoft : t.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? t.accent : t.tbBorder,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Column(children: [
            NoteeIconWidget(icon,
                size: 18, color: selected ? t.accent : t.ink),
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
            const SizedBox(height: 3),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 9.5,
                color: t.inkFaint,
                height: 1.1,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
