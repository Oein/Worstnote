// PageToolbar — the editor's tool / width / color row, styled per the
// Claude Design handoff. Three pill-bordered groups left-aligned; activate-
// while-active or long-press a primary tool to open a Notee popover with
// variants and finer settings.
//
// This file is split into parts (pen, eraser, lasso, text, shape, width/color)
// to keep the per-file size manageable. All parts share the imports declared
// here and may freely reference one another's `_`-prefixed types.

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

part 'toolbar_pen.part.dart';
part 'toolbar_eraser.part.dart';
part 'toolbar_lasso.part.dart';
part 'toolbar_text.part.dart';
part 'toolbar_shape.part.dart';
part 'toolbar_width_color.part.dart';

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

    final body = Path()
      ..moveTo(w * 0.10, h * 0.38)
      ..lineTo(w * 0.20, h * 0.50)
      ..lineTo(w * 0.10, h * 0.62)
      ..lineTo(w * 0.90, h * 0.62)
      ..lineTo(w * 0.80, h * 0.50)
      ..lineTo(w * 0.90, h * 0.38)
      ..close();
    canvas.drawPath(body, stroke);

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

    canvas.save();
    canvas.translate(w * 0.5, h * 0.5);
    canvas.rotate(2.356194); // 135°
    canvas.translate(-w * 0.5, -h * 0.5);

    final body = Rect.fromLTWH(w * 0.18, h * 0.30, w * 0.55, h * 0.40);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(1.5)),
      stroke,
    );
    canvas.drawLine(
      Offset(w * 0.62, h * 0.30),
      Offset(w * 0.62, h * 0.70),
      stroke,
    );

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

// ── Helpers ───────────────────────────────────────────────────────────

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
