// PageToolbar — the editor's tool / width / color row, styled per the
// Claude Design handoff. Three pill-bordered groups left-aligned; activate-
// while-active or long-press a primary tool to open a Notee popover with
// variants and finer settings.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/page_object.dart';
import '../canvas/painters/text_painter_widget.dart';
import '../canvas/selection/selection_state.dart';
import '../../features/notebook/notebook_state.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_popover.dart';
import '../../theme/notee_theme.dart';
import 'tool_state.dart';
import 'toolbar_shell.dart' show ToolbarDock, toolbarDockProvider;

/// Returns the popover placement that opens away from the toolbar based
/// on the current dock position. Read this inside any toolbar button that
/// shows a detail popover.
NoteePopoverPlacement toolbarPopoverPlacement(WidgetRef ref) {
  final dock = ref.read(toolbarDockProvider);
  switch (dock) {
    case ToolbarDock.left:
      return NoteePopoverPlacement.right;
    case ToolbarDock.right:
      return NoteePopoverPlacement.left;
    case ToolbarDock.bottom:
      return NoteePopoverPlacement.above;
    case ToolbarDock.top:
    case ToolbarDock.floating:
      return NoteePopoverPlacement.below;
  }
}

/// True when the toolbar is docked vertically (left/right). Detail popovers
/// that lay out variant buttons in a row should switch to a column instead.
bool toolbarIsVerticalDock(WidgetRef ref) {
  final dock = ref.read(toolbarDockProvider);
  return dock == ToolbarDock.left || dock == ToolbarDock.right;
}

class PageToolbarBar extends ConsumerWidget {
  const PageToolbarBar({super.key, this.axis = Axis.horizontal});

  final Axis axis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final canUndo = ref.watch(canUndoProvider);
    final canRedo = ref.watch(canRedoProvider);
    final ctl = ref.read(notebookProvider.notifier);
    final activeTool = ref.watch(toolProvider.select((s) => s.activeTool));
    final isEraserArea = activeTool == AppTool.eraserArea;
    final isEraserStroke = activeTool == AppTool.eraserStroke;
    final isEraser = isEraserArea || isEraserStroke;
    final isSelect = activeTool == AppTool.lasso || activeTool == AppTool.rectSelect;

    final border = axis == Axis.horizontal
        ? Border(bottom: BorderSide(color: t.tbBorder, width: 0.5))
        : Border(right: BorderSide(color: t.tbBorder, width: 0.5));

    if (axis == Axis.vertical) {
      return Container(
        decoration: BoxDecoration(color: t.toolbar, border: border),
        width: 36,
        height: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 4),
              _ToolsGroup(axis: Axis.vertical),
              if (!isEraser && !isSelect) ...[
                _ToolbarDivider(axis: Axis.vertical),
                _WidthGroup(axis: Axis.vertical),
                _ToolbarDivider(axis: Axis.vertical),
                _ColorGroup(axis: Axis.vertical),
              ],
              _ToolbarDivider(axis: Axis.vertical),
              IconButton(
                tooltip: 'Undo (⌘Z)',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: NoteeIconWidget(NoteeIcon.undo, size: 15,
                    color: canUndo ? t.ink : t.inkFaint),
                onPressed: canUndo ? ctl.undo : null,
              ),
              IconButton(
                tooltip: 'Redo (⌘⇧Z)',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: NoteeIconWidget(NoteeIcon.redo, size: 15,
                    color: canRedo ? t.ink : t.inkFaint),
                onPressed: canRedo ? ctl.redo : null,
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(color: t.toolbar, border: border),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _ToolsGroup(axis: Axis.horizontal),
          if (!isEraser && !isSelect) ...[
            _ToolbarDivider(axis: Axis.horizontal),
            _WidthGroup(axis: Axis.horizontal),
            _ToolbarDivider(axis: Axis.horizontal),
            _ColorGroup(axis: Axis.horizontal),
          ],
          if (isEraser) ...[
            _ToolbarDivider(axis: Axis.horizontal),
            const _EraserAreaSlider(),
          ],
          _ToolbarDivider(axis: Axis.horizontal),
          IconButton(
            tooltip: 'Undo (⌘Z)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: NoteeIconWidget(NoteeIcon.undo, size: 15,
                color: canUndo ? t.ink : t.inkFaint),
            onPressed: canUndo ? ctl.undo : null,
          ),
          IconButton(
            tooltip: 'Redo (⌘⇧Z)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: NoteeIconWidget(NoteeIcon.redo, size: 15,
                color: canRedo ? t.ink : t.inkFaint),
            onPressed: canRedo ? ctl.redo : null,
          ),
        ]),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider({required this.axis});
  final Axis axis;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Padding(
      padding: axis == Axis.horizontal
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 4)
          : const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Container(
        width: axis == Axis.horizontal ? 0.5 : 22,
        height: axis == Axis.horizontal ? 22 : 0.5,
        color: t.tbBorder,
      ),
    );
  }
}

class _PillGroup extends StatelessWidget {
  const _PillGroup({required this.children, this.axis = Axis.horizontal});
  final List<Widget> children;
  final Axis axis;
  @override
  Widget build(BuildContext context) {
    return axis == Axis.horizontal
        ? Row(mainAxisSize: MainAxisSize.min, children: children)
        : Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

// ── Tools group ──────────────────────────────────────────────────────
class _ToolsGroup extends ConsumerWidget {
  const _ToolsGroup({this.axis = Axis.horizontal});
  final Axis axis;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _PillGroup(axis: axis, children: [
      _PenButton(),
      const _HighlighterButton(),
      _EraserButton(),
      const _LassoButton(),
      _TextButton(),
      _ShapeButton(),
      const _TapeButton(),
    ]);
  }
}

class _SimpleToolBtn extends ConsumerWidget {
  const _SimpleToolBtn({required this.icon, required this.app});
  final NoteeIcon icon;
  final AppTool app;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final active =
        ref.watch(toolProvider.select((s) => s.activeTool == app));
    return _GlyphButton(
      onTap: () => ref.read(toolProvider.notifier).setTool(app),
      active: active,
      child: NoteeIconWidget(icon,
          size: 15, color: active ? t.accent : t.ink),
    );
  }
}

class _TapeButton extends ConsumerWidget {
  const _TapeButton();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final active = ref.watch(
        toolProvider.select((s) => s.activeTool == AppTool.tape));
    return _GlyphButton(
      onTap: () => ref.read(toolProvider.notifier).setTool(AppTool.tape),
      active: active,
      child: SizedBox(
        width: 16,
        height: 16,
        child: CustomPaint(
          painter: _TapeGlyphPainter(color: active ? t.accent : t.ink),
        ),
      ),
    );
  }
}

class _HighlighterButton extends ConsumerWidget {
  const _HighlighterButton();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final active = ref.watch(
        toolProvider.select((s) => s.activeTool == AppTool.highlighter));
    return _GlyphButton(
      onTap: () =>
          ref.read(toolProvider.notifier).setTool(AppTool.highlighter),
      active: active,
      child: SizedBox(
        width: 16,
        height: 16,
        child: CustomPaint(
          painter:
              _HighlighterGlyphPainter(color: active ? t.accent : t.ink),
        ),
      ),
    );
  }
}

class _GlyphButton extends StatelessWidget {
  const _GlyphButton({
    required this.child,
    required this.active,
    required this.onTap,
    this.onLongPress,
    this.anchorKey,
  });
  final Widget child;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final GlobalKey? anchorKey;
  static const double size = 28;
  static const _dur = Duration(milliseconds: 140);
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final box = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: _dur,
        curve: Curves.easeOut,
        width: size,
        height: size,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: active ? t.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: active
              ? Border.all(color: t.accent.withValues(alpha: 0.6), width: 0.5)
              : Border.all(color: Colors.transparent, width: 0.5),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
    if (anchorKey != null) return KeyedSubtree(key: anchorKey, child: box);
    return box;
  }
}

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

    // Auto-close the panel when the user switches away from the pen tool.
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

    // Sync text field when value changes externally (cross-instance sync).
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

// ── Text button (opens format bar when active) ───────────────────────
class _TextButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends ConsumerState<_TextButton> {
  final _key = GlobalKey();
  VoidCallback? _dismiss;
  bool _barOpen = false;

  @override
  void dispose() {
    _dismiss?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final active =
        ref.watch(toolProvider.select((s) => s.activeTool == AppTool.text));

    ref.listen(toolProvider.select((s) => s.activeTool), (_, next) {
      if (next == AppTool.text && !_barOpen) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) { if (mounted) _openBar(); });
      } else if (next != AppTool.text && _barOpen) {
        _closeBar();
      }
    });

    return _GlyphButton(
      anchorKey: _key,
      active: active,
      onTap: () {
        if (active) {
          // Bar should always be visible while text is active — just re-anchor
          // it if somehow closed.
          if (!_barOpen) _openBar();
        } else {
          ref.read(toolProvider.notifier).setTool(AppTool.text);
        }
      },
      child: NoteeIconWidget(NoteeIcon.text,
          size: 15, color: active ? t.accent : t.ink),
    );
  }

  void _openBar() {
    if (_barOpen || !mounted) return;
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _key,
      maxWidth: null, // size to the row's intrinsic width — no clipping
      placement: toolbarPopoverPlacement(ref),
      onDismiss: () {
        if (!mounted) return;
        setState(() { _dismiss = null; _barOpen = false; });
      },
      builder: (ctx, dismiss) => _TextFormatBarBody(dismiss: dismiss),
    );
    setState(() { _dismiss = dismiss; _barOpen = true; });
  }

  void _closeBar() {
    _dismiss?.call();
    if (mounted) setState(() { _dismiss = null; _barOpen = false; });
  }
}

/// A tap-to-type font-size widget used inside the text format bar.
class _FontSizeInput extends StatefulWidget {
  const _FontSizeInput({
    required this.value,
    required this.onChanged,
    required this.color,
  });
  final double value;
  final void Function(double) onChanged;
  final Color color;
  @override
  State<_FontSizeInput> createState() => _FontSizeInputState();
}

class _FontSizeInputState extends State<_FontSizeInput> {
  late final TextEditingController _ctl;
  late final FocusNode _node;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.value.round().toString());
    _node = FocusNode();
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _FontSizeInput old) {
    super.didUpdateWidget(old);
    // Mirror external changes when not focused for editing.
    if (!_node.hasFocus && widget.value.round().toString() != _ctl.text) {
      _ctl.text = widget.value.round().toString();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    _ctl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_node.hasFocus) _commit();
  }

  void _commit() {
    final v = double.tryParse(_ctl.text);
    if (v == null) {
      _ctl.text = widget.value.round().toString();
      return;
    }
    final clamped = v.clamp(8.0, 200.0);
    if (clamped != widget.value) widget.onChanged(clamped);
    _ctl.text = clamped.round().toString();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 22,
      child: TextField(
        controller: _ctl,
        focusNode: _node,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          color: widget.color,
          fontWeight: FontWeight.w600,
        ),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

class _TextFormatBarBody extends ConsumerWidget {
  const _TextFormatBarBody({required this.dismiss});
  final VoidCallback dismiss;

  static const _families = <String, String>{
    // Use system fonts that are actually installed (we don't bundle font
    // assets) so the three options visibly differ. macOS / iOS resolve
    // these natively; other platforms fall back to a similar family.
    'Sans': 'Helvetica Neue',
    'Serif': 'Times New Roman',
    'Mono': 'Menlo',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final t = NoteeProvider.of(context).tokens;

    // Resolve the editing text box (if any) so the indicator state in the
    // bar shows that box's properties rather than ToolState defaults.
    final editingId = ref.watch(editingTextBoxIdProvider);
    TextBoxObject? editingBox;
    if (editingId != null) {
      final notebook = ref.read(notebookProvider);
      outer:
      for (final pageId in notebook.textsByPage.keys) {
        for (final b in notebook.textsByPage[pageId]!) {
          if (b.id == editingId && !b.deleted) {
            editingBox = b;
            break outer;
          }
        }
      }
    }
    final indicatorSize = editingBox?.fontSizePt ?? s.textFontSizePt;
    final indicatorWeight = editingBox?.fontWeight ?? s.textFontWeight;
    final indicatorFamily = editingBox?.fontFamily ?? s.textFontFamily;
    final indicatorItalic = editingBox?.italic ?? s.textItalic;
    final indicatorAlign = editingBox?.textAlign ?? s.textAlign;
    final indicatorBold = indicatorWeight >= 700;

    // If a text box is currently being edited, font/weight/family/italic
    // changes should also be applied live to that box, not only saved as
    // future-text defaults in ToolState.
    void applyToEditing(TextBoxObject Function(TextBoxObject) mutate) {
      final id = ref.read(editingTextBoxIdProvider);
      if (id == null) return;
      final notebook = ref.read(notebookProvider);
      for (final pageId in notebook.textsByPage.keys) {
        for (final box in notebook.textsByPage[pageId]!) {
          if (box.id != id || box.deleted) continue;
          final next = withRemeasuredHeight(
            mutate(box).copyWith(rev: box.rev + 1),
          );
          ref.read(notebookProvider.notifier).updateText(next);
          return;
        }
      }
    }

    Widget divider() => Container(
          width: 0.5, height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          color: t.rule,
        );

    Widget fmtBtn({
      required IconData icon,
      required bool sel,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        child: GestureDetector(
          onTap: onTap,
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
            child: Icon(icon, size: 15, color: sel ? t.accent : t.ink),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        // Font size
        GestureDetector(
          onTap: () {
            final v = (indicatorSize - 2).clamp(8.0, 96.0);
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          child: Icon(Icons.remove, size: 14, color: t.ink),
        ),
        // Tap the size number to type a custom value.
        _FontSizeInput(
          value: indicatorSize,
          onChanged: (v) {
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          color: t.ink,
        ),
        GestureDetector(
          onTap: () {
            final v = (indicatorSize + 2).clamp(8.0, 96.0);
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          child: Icon(Icons.add, size: 14, color: t.ink),
        ),
        divider(),
        // Font family
        for (final entry in _families.entries)
          GestureDetector(
            onTap: () {
              ctl.setTextFontFamily(entry.value);
              applyToEditing((b) => b.copyWith(fontFamily: entry.value));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: indicatorFamily == entry.value
                    ? t.accentSoft
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: indicatorFamily == entry.value
                    ? Border.all(
                        color: t.accent.withValues(alpha: 0.6), width: 0.5)
                    : null,
              ),
              child: Text(
                entry.key,
                style: TextStyle(
                  fontFamily: entry.value,
                  fontSize: 12,
                  color: indicatorFamily == entry.value ? t.accent : t.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        divider(),
        fmtBtn(
          icon: Icons.format_bold_rounded,
          sel: indicatorBold,
          onTap: () {
            final w = indicatorBold ? 400 : 700;
            ctl.setTextFontWeight(w);
            applyToEditing((b) => b.copyWith(fontWeight: w));
          },
          tooltip: 'Bold',
        ),
        fmtBtn(
          icon: Icons.format_italic_rounded,
          sel: indicatorItalic,
          onTap: () {
            final v = !indicatorItalic;
            ctl.setTextItalic(v);
            applyToEditing((b) => b.copyWith(italic: v));
          },
          tooltip: 'Italic',
        ),
        divider(),
        fmtBtn(
          icon: Icons.format_align_left_rounded,
          sel: indicatorAlign == 0,
          onTap: () {
            ctl.setTextAlign(0);
            applyToEditing((b) => b.copyWith(textAlign: 0));
          },
          tooltip: 'Left',
        ),
        fmtBtn(
          icon: Icons.format_align_center_rounded,
          sel: indicatorAlign == 1,
          onTap: () {
            ctl.setTextAlign(1);
            applyToEditing((b) => b.copyWith(textAlign: 1));
          },
          tooltip: 'Center',
        ),
        fmtBtn(
          icon: Icons.format_align_right_rounded,
          sel: indicatorAlign == 2,
          onTap: () {
            ctl.setTextAlign(2);
            applyToEditing((b) => b.copyWith(textAlign: 2));
          },
          tooltip: 'Right',
        ),
      ]),
    );
  }
}

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
        // Shape picker
        for (final app in shapes) shapeBtn(app),
        divider(),
        // Fill toggle
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
        // Fill color swatches — same 6 palette colors as pen group
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
        // Glyph: diagonal line (↗) with arrowhead at top-right.
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
        // Glyph: simple diagonal line.
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

    // Rounded square — upper-right
    final sq = Rect.fromLTWH(w * 0.38, h * 0.08, w * 0.50, h * 0.50);
    canvas.drawRRect(
      RRect.fromRectAndRadius(sq, const Radius.circular(2)),
      stroke,
    );

    // Triangle — lower-right, overlapping the square
    final tri = Path()
      ..moveTo(w * 0.38, h * 0.92)
      ..lineTo(w * 0.82, h * 0.92)
      ..lineTo(w * 0.60, h * 0.50)
      ..close();
    canvas.drawPath(tri, stroke);

    // Circle — left side
    canvas.drawCircle(Offset(w * 0.22, h * 0.52), w * 0.18, stroke);
  }

  @override
  bool shouldRepaint(covariant _ShapeToolGlyphPainter old) => old.color != color;
}

/// Toolbar tape button glyph: a piece of washi tape — a horizontal
/// rectangle with notched (zig-zag) ends and a small inner detail line.
class _TapeGlyphPainter extends CustomPainter {
  _TapeGlyphPainter({required this.color});
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

    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(-0.4); // ~-23°
    canvas.translate(-w * 0.5, -h * 0.5);

    // Tape outline with notched (V) cuts at left & right ends
    final body = Path()
      ..moveTo(w * 0.10, h * 0.38)
      ..lineTo(w * 0.20, h * 0.50) // left notch in
      ..lineTo(w * 0.10, h * 0.62)
      ..lineTo(w * 0.90, h * 0.62)
      ..lineTo(w * 0.80, h * 0.50) // right notch in
      ..lineTo(w * 0.90, h * 0.38)
      ..close();
    canvas.drawPath(body, stroke);

    // Small inner perforation circle to suggest a tape hole / spool eye
    canvas.drawCircle(Offset(w * 0.5, h * 0.50), 1.4, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TapeGlyphPainter old) => old.color != color;
}

/// Toolbar highlighter button glyph: a chisel-tip marker shape.
class _HighlighterGlyphPainter extends CustomPainter {
  _HighlighterGlyphPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;

    // Marker shape, drawn on a 45° diagonal axis. Rotated 180° from the
    // earlier orientation so the tip points to the lower-left.
    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(2.356194); // 135° (=-45° + 180°)
    canvas.translate(-w * 0.5, -h * 0.5);

    // Body (longer rounded rectangle)
    final body = Rect.fromLTWH(w * 0.18, h * 0.30, w * 0.55, h * 0.40);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(1.5)),
      stroke,
    );
    // Cap separator line near the right end
    canvas.drawLine(
      Offset(w * 0.62, h * 0.30),
      Offset(w * 0.62, h * 0.70),
      stroke,
    );

    // Tip (chisel) — small filled trapezoid extending right from body
    final tip = Path()
      ..moveTo(w * 0.73, h * 0.36)
      ..lineTo(w * 0.90, h * 0.42)
      ..lineTo(w * 0.90, h * 0.58)
      ..lineTo(w * 0.73, h * 0.64)
      ..close();
    canvas.drawPath(tip, fill);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HighlighterGlyphPainter old) =>
      old.color != color;
}

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
  int? _styleSlot; // null = closed; negative = style-only; 0..4 = slot editor
  int? _editingSlot;
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
    setState(() { _styleSlot = slotIndex; _editingSlot = slotIndex; _dismiss = dismiss; });
  }

  void _close() {
    _dismiss?.call();
    if (mounted) setState(() { _styleSlot = null; _editingSlot = null; _dismiss = null; });
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
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
              // Each pen-palette slot remembers its own line style.
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
                  // Adopt this slot's line style as the active pen style.
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
        // Header
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
        // Style tiles — only for pen
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
          // Dash gap slider — only when dashed or dotted is active
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
        // Width slider (range depends on active tool)
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
      // dashed
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
      // dotted
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
    // Height of the preview encodes the stroke width.
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
      // solid — draw as rounded rectangle (pill shape)
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(size.height / 2),
      );
      canvas.drawRRect(rect, Paint()..color = color);
    } else if (lineStyle == 1) {
      // dashed
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
      // dotted
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
        // Header
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
        // Saturation × Value square
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
        // Hue slider
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
        // Hex input + preview
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
        // Opacity slider
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


int _argb(Color c) {
  final a = (c.a * 255).round() & 0xff;
  final r = (c.r * 255).round() & 0xff;
  final g = (c.g * 255).round() & 0xff;
  final b = (c.b * 255).round() & 0xff;
  return (a << 24) | (r << 16) | (g << 8) | b;
}

bool _isEraserTool(AppTool t) =>
    t == AppTool.eraserArea || t == AppTool.eraserStroke;

List<int> _activePaletteColors(ToolState s, {bool isDark = false}) {
  switch (s.activeTool) {
    case AppTool.highlighter:
      return s.highlighterPaletteColors;
    case AppTool.tape:
      return s.tapePaletteColors;
    default:
      if (!isDark) return s.penPaletteColors;
      return s.penPaletteColors.map((c) {
        final hsl = HSLColor.fromColor(Color(c));
        if (hsl.lightness < 0.25) {
          return HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.1, 0.88)
              .toColor()
              .value;
        }
        return c;
      }).toList();
  }
}

List<double> _activePaletteWidths(ToolState s) {
  switch (s.activeTool) {
    case AppTool.highlighter:
      return s.highlighterPaletteWidths;
    case AppTool.tape:
      return s.tapePaletteWidths;
    default:
      return s.penPaletteWidths;
  }
}

double _sliderMinFor(AppTool t) =>
    t == AppTool.highlighter ? 8.0 : (t == AppTool.tape ? 12.0 : 0.3);

double _sliderMaxFor(AppTool t) =>
    t == AppTool.highlighter ? 40.0 : (t == AppTool.tape ? 60.0 : 12.0);

double _activeWidth(ToolState s) {
  switch (s.activeTool) {
    case AppTool.pen:
      return s.penWidth;
    case AppTool.highlighter:
      return s.highlighterWidth;
    case AppTool.tape:
      return s.tapeWidth;
    case AppTool.eraserArea:
    case AppTool.eraserStroke:
      return s.eraserAreaRadius;
    default:
      return s.penWidth;
  }
}

int _activeColor(ToolState s) {
  switch (s.activeTool) {
    case AppTool.pen:
      return s.penColor;
    case AppTool.highlighter:
      return s.highlighterColor;
    case AppTool.tape:
      return s.tapeColor;
    default:
      return s.penColor;
  }
}

void _setWidthForActive(ToolState s, ToolController c, double w) {
  switch (s.activeTool) {
    case AppTool.highlighter:
      c.setHighlighterWidth(w);
    case AppTool.tape:
      c.setTapeWidth(w);
    case AppTool.eraserArea:
    case AppTool.eraserStroke:
      c.setEraserAreaRadius(w);
    default:
      c.setPenWidth(w);
  }
}

void _setColorForActive(ToolState s, ToolController c, int argb) {
  switch (s.activeTool) {
    case AppTool.highlighter:
      c.setHighlighterColor(argb);
    case AppTool.tape:
      c.setTapeColor(argb);
    default:
      c.setPenColor(argb);
  }
}

