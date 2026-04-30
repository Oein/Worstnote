// CanvasView wires PointerEvents → tool-specific gesture handler →
// painters/state. Multiple tools share this single widget; the handler
// branches on the AppTool from `toolProvider`.
//
// Tape semantics: tape is a stroke whose `tool == ToolKind.tape`.
//   - Drag with the tape tool → draws a tape stroke (thick, opaque).
//   - Tap (no drag) on an existing tape stroke → toggles its rendered
//     opacity between full and ~10% via the runtime `_revealedTapeIds`
//     set. The toggle state is *not* persisted.
//
// All persistent edits go through the [NotebookController] (Riverpod), so
// drawing is reactive and the UI re-renders strictly from state.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ids.dart';
import '../../../domain/layer.dart';
import '../../../features/import/asset_service.dart';
import '../../../domain/page.dart';
import '../../../domain/page_object.dart';
import '../../../domain/stroke.dart';
import '../../notebook/notebook_state.dart';
import '../../toolbar/tool_state.dart';
import '../engine/input_gate.dart';
import '../engine/spen_state.dart';
import '../engine/lasso.dart' as geom;
import '../engine/shape_recognizer.dart' as rec;
import '../engine/drawn_shape_recognizer.dart';
import '../../../core/one_euro_filter.dart';
import '../engine/stroke_builder.dart';
import '../painters/active_stroke_painter.dart';
import '../painters/background_painter.dart';
import '../painters/layer_painter.dart';
import '../painters/overlay_painter.dart';
import '../painters/shape_painter.dart';
import '../painters/text_painter_widget.dart';
import '../selection/selection_overlay.dart';
import '../selection/selection_state.dart';
import 'background_image_layer.dart';

class CanvasView extends ConsumerStatefulWidget {
  const CanvasView({
    super.key,
    required this.page,
    required this.layers,
    required this.strokesByLayer,
    required this.activeLayerId,
    required this.tool,
    required this.colorArgb,
    required this.widthPt,
    required this.opacity,
    required this.onStrokeCommitted,
    this.shapesByLayer = const {},
    this.textsByLayer = const {},
    this.imagesByLayer = const {},
    this.onShapeCommitted,
    this.onTextCommitted,
    this.onTextChanged,
    this.onEraseStrokes,
    this.onEraseObjects,
    this.inputMode = InputMode.any,
    this.isPinching = false,
    this.layerCaches,
    this.tapeCaches,
    this.zoomNotifier,
  });

  final NotePage page;
  final List<Layer> layers;
  final Map<String, List<Stroke>> strokesByLayer;
  final Map<String, List<ShapeObject>> shapesByLayer;
  final Map<String, List<TextBoxObject>> textsByLayer;
  final Map<String, List<ImageObject>> imagesByLayer;
  final String activeLayerId;
  final ToolKind tool;
  final int colorArgb;
  final double widthPt;
  final double opacity;
  final void Function(Stroke stroke) onStrokeCommitted;
  final void Function(ShapeObject)? onShapeCommitted;
  final void Function(TextBoxObject)? onTextCommitted;
  final void Function(TextBoxObject)? onTextChanged;
  final void Function(Set<String> ids)? onEraseStrokes;
  final void Function(Set<String> ids)? onEraseObjects;
  final InputMode inputMode;
  final bool isPinching;
  // External cache maps — owned by the editor so they survive page dispose.
  final Map<String, LayerCache>? layerCaches;
  final Map<String, LayerCache>? tapeCaches;
  // Current canvas zoom — used by the leash smoother to keep physical feel constant.
  final ValueNotifier<double>? zoomNotifier;

  @override
  ConsumerState<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends ConsumerState<CanvasView> {
  // Per-layer paint cache — backed by the external map when provided so the
  // cache survives widget dispose/remount (page scrolled off-screen).
  Map<String, LayerCache> get _layerCaches =>
      widget.layerCaches ?? _localLayerCaches;
  Map<String, LayerCache> get _tapeCaches =>
      widget.tapeCaches ?? _localTapeCaches;
  final Map<String, LayerCache> _localLayerCaches = {};
  final Map<String, LayerCache> _localTapeCaches = {};

  // For pen / highlighter / eraserStroke / tape (tape is a stroke too).
  StrokeBuilder? _builder;
  final ValueNotifier<List<StrokePoint>> _liveNotifier =
      ValueNotifier(const []);
  Offset? _strokeDownPos;
  bool _movedPastTapThreshold = false;
  static const double _tapMovementThreshold = 4.0;

  // Shift + highlighter straight-line mode.
  bool _highlighterStraightLine = false;

  // S-Pen button activates a temporary eraser.
  bool _tempErasing = false;

  // Leash smoothing: P is the actual drawn position, M is the raw pointer.
  // P only moves when M is farther than leashLocal from P.
  // Max physical leash at smoothing=1.0. Scales linearly with smoothing,
  // so smoothing=0 → leash=0 → raw passthrough.
  static const double _leashMaxPx = 20.0;
  double _strokeSmoothing = 0.0; // set at pen-down from tool state
  double _leashMultiplier = 1.0;
  Offset? _leashP;

  // "Draw and hold" shape recognition (pen tool only).
  Timer? _shapeHoldTimer;
  List<StrokePoint>? _recognizedShapePts; // non-null after snap fires
  Offset? _lastTimerRawPt; // last point that armed/reset _shapeHoldTimer
  // Raw pointer-event positions (pre-leash, pre-OneEuro) used as input to the
  // shape recognizer so smoothing artifacts don't bias the classification.
  final List<StrokePoint> _rawShapePts = <StrokePoint>[];
  static const Duration _shapeHoldDuration = Duration(milliseconds: 600);

  static bool _isStylusButtonHeld(PointerEvent e) =>
      e.kind == PointerDeviceKind.invertedStylus ||
      // Samsung S-Pen side button: reported as secondary button (0x02).
      (e.kind == PointerDeviceKind.stylus && e.buttons & 0x02 != 0);

  // For shape / rectSelect / text-creation gestures.
  Offset? _dragStart;
  Offset? _dragCurrent;
  bool _shiftHeld = false;
  // Shape-tool auto-regularize: when the pointer holds still long enough
  // during a shape drag, snap to the regular form (square / circle /
  // equilateral triangle / regular diamond). Resumes free dimensions as
  // soon as the pointer moves again.
  bool _autoRegularize = false;
  DateTime? _autoRegularizeSince;
  Timer? _stillTimer;
  static const Duration _stillDelay = Duration(milliseconds: 450);
  // Pointer must remain still for at least this long AFTER the snap fires
  // before the regularized form is allowed to be committed on release.
  static const Duration _snapHoldGrace = Duration(milliseconds: 50);
  static const double _stillMoveSlop = 1.5;

  // Currently-editing text box ID (text tool only). Mirror to a global
  // provider via [_setEditingTextBoxId] so the toolbar's text format bar
  // can apply font/weight/etc. changes live to the box being edited.
  String? _editingTextBoxId;

  void _setEditingTextBoxId(String? id) {
    // If we are leaving (or switching away from) editing a text box that
    // has no content, delete it — empty boxes are clutter and the user
    // didn't commit any text.
    final prev = _editingTextBoxId;
    if (prev != null && prev != id) {
      final box = _findTextById(prev);
      if (box != null && box.text.trim().isEmpty) {
        widget.onTextChanged
            ?.call(box.copyWith(deleted: true, rev: box.rev + 1));
      }
    }
    _editingTextBoxId = id;
    // Sync to the global provider IMMEDIATELY (no microtask) so the
    // hardware-key handler in main.dart sees the change before the next
    // keystroke is processed.
    ref.read(editingTextBoxIdProvider.notifier).state = id;
  }

  // For lasso.
  final List<geom.Point2> _lassoPoints = <geom.Point2>[];

  // Persisted selection outline — shown after gesture completes.
  List<geom.Point2> _committedLasso = const [];
  Rect? _committedSelectRect;

  // Selection drag (translate selected objects).
  bool _selectionDragging = false;
  Offset? _selectionDragStart;
  Offset? _selectionDragLast;

  // Selection scale (drag a handle to resize the selection bbox).
  SelectionHandle? _scaleHandle;
  Rect? _scaleStartBbox;

  // Selection rotate (drag the small circle above the bbox to rotate).
  Rect? _rotateStartBbox;
  double _rotateStartAngle = 0.0;
  // Rotation accumulated within the *current* drag (added to base on commit).
  double _rotateAccumRad = 0.0;
  // Rotation that has been committed across previous drags — kept so the
  // bbox stays visually rotated after the user releases. Cleared when the
  // selection identity changes (new objects, or cleared).
  double _rotateBaseRad = 0.0;
  // Identity of the selection the current rotation belongs to. When the
  // selection changes, [_rotateBaseRad] is reset to 0.
  int _rotationSelectionToken = 0;

  // Text-tool gesture state machine. Idle is the default; selectMaybeEdit
  // captures a pointer-down on an already-selected box and resolves to
  // either "edit" (tap, no movement) or "drag" (movement past slop).
  // dragging / scaling / editing are reflected by other fields
  // (_selectionDragging, _scaleHandle, _editingTextBoxId) — this enum just
  // disambiguates the single ambiguous case.
  String? _textTapPendingEditId;
  static const double _textDragSlop = 4.0;

  // Unified cursor position — updated on hover and on every pointer move.
  // Drives both the brush-size circle and the eraser circle.
  final ValueNotifier<Offset?> _cursorNotifier = ValueNotifier(null);


  /// Current canvas zoom (defaults to 1.0 if no notifier is wired).
  double _currentZoom() => widget.zoomNotifier?.value ?? 1.0;

  /// Rotates [pt] by -[angle] around [center]. Used to map a screen-space
  /// pointer into the bbox's unrotated reference frame so handle hit-tests
  /// and rotate-angle math work as if the bbox were axis-aligned.
  Offset _unrotatePoint(Offset pt, Offset center, double angle) {
    if (angle == 0) return pt;
    final cosA = math.cos(-angle);
    final sinA = math.sin(-angle);
    final dx = pt.dx - center.dx;
    final dy = pt.dy - center.dy;
    return Offset(
      center.dx + dx * cosA - dy * sinA,
      center.dy + dx * sinA + dy * cosA,
    );
  }

  /// Resets the persistent rotation base — call when a new selection takes
  /// hold so the next rotation drag starts from 0.
  void _maybeResetRotationBase(int newToken) {
    if (newToken != _rotationSelectionToken) {
      _rotationSelectionToken = newToken;
      _rotateBaseRad = 0.0;
    }
  }

  LayerCache _cacheFor(String id) =>
      _layerCaches.putIfAbsent(id, LayerCache.new);

  LayerCache _tapeCacheFor(String id) =>
      _tapeCaches.putIfAbsent(id, LayerCache.new);

  void _invalidateLayer(String layerId) {
    _cacheFor(layerId).invalidate();
    _tapeCacheFor(layerId).invalidate();
  }

  // Invalidate the layer picture cache whenever stroke/shape/text data changes
  // from an external source (undo, redo, sync). Without this, the canvas keeps
  // painting the stale cached picture even after the state has been restored.
  @override
  void didUpdateWidget(CanvasView old) {
    super.didUpdateWidget(old);
    // Cancel an in-progress stroke when pinching starts.
    if (widget.isPinching && !old.isPinching && _builder != null) {
      _builder = null;
      _liveNotifier.value = const [];
      _strokeDownPos = null;
      _shapeHoldTimer?.cancel();
      _shapeHoldTimer = null;
      _recognizedShapePts = null;
      _rawShapePts.clear();
      _lastTimerRawPt = null;
    }
    if (!identical(old.strokesByLayer, widget.strokesByLayer) ||
        !identical(old.shapesByLayer, widget.shapesByLayer) ||
        !identical(old.textsByLayer, widget.textsByLayer)) {
      for (final layer in widget.layers) {
        final strokesChanged = !identical(
            old.strokesByLayer[layer.id], widget.strokesByLayer[layer.id]);
        final shapesChanged = !identical(
            old.shapesByLayer[layer.id], widget.shapesByLayer[layer.id]);
        final textsChanged = !identical(
            old.textsByLayer[layer.id], widget.textsByLayer[layer.id]);
        if (strokesChanged || shapesChanged || textsChanged) {
          _invalidateLayer(layer.id);
        }
      }
    }
  }

  void _toggleTape(String strokeId, String layerId) {
    ref.read(notebookProvider.notifier).toggleTapeRevealed(strokeId);
    _invalidateLayer(layerId);
  }

  // ── Tool dispatching ───────────────────────────────────────────────
  // Branch decisions read AppTool from the provider — `widget.tool` is the
  // ToolKind for stroke construction only, and `toolKindFor()` collapses
  // non-stroke tools to ToolKind.pen, so we can't switch on widget.tool.
  AppTool _appTool() => ref.read(toolProvider).activeTool;

  bool _isStrokeAppTool(AppTool t) =>
      t == AppTool.pen ||
      t == AppTool.highlighter ||
      t == AppTool.eraserStroke ||
      t == AppTool.tape;

  bool _isDragRectAppTool(AppTool t) =>
      t == AppTool.rectSelect ||
      t == AppTool.shapeRect ||
      t == AppTool.shapeEllipse ||
      t == AppTool.shapeTriangle ||
      t == AppTool.shapeDiamond ||
      t == AppTool.shapeArrow ||
      t == AppTool.shapeLine ||
      t == AppTool.text;

  // ── Pointer handling ───────────────────────────────────────────────
  // Handles interactions available even in stylusOnly mode (finger/touch):
  // exiting text editing, dragging/scaling the current selection.
  void _handleNonDrawingDown(PointerDownEvent e) {
    if (_editingTextBoxId != null) {
      final selectedId = _editingTextBoxId!;
      final prevBox = _findTextById(selectedId);
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _setEditingTextBoxId(null));
      if (prevBox != null && prevBox.text.trim().isNotEmpty) {
        final fresh = withRemeasuredHeight(prevBox);
        if (fresh.bbox.maxY != prevBox.bbox.maxY) {
          widget.onTextChanged?.call(fresh);
        }
        final r = Rect.fromLTRB(fresh.bbox.minX, fresh.bbox.minY,
            fresh.bbox.maxX, fresh.bbox.maxY);
        ref.read(selectionProvider.notifier).replace(SelectionState(
              textIds: {selectedId},
              bbox: r,
              pageId: widget.page.id,
            ));
      } else {
        ref.read(selectionProvider.notifier).clear();
      }
      return;
    }
    final sel = ref.read(selectionProvider);
    _maybeResetRotationBase(Object.hashAll(sel.strokeIds.toList()
      ..addAll(sel.shapeIds)
      ..addAll(sel.textIds)));
    if (sel.isNotEmpty && sel.pageId == widget.page.id) {
      final bbox = sel.bbox;
      if (bbox != null) {
        final z = _currentZoom();
        // Map pointer through the inverse persistent rotation so handle
        // hit-tests run in the bbox's unrotated frame.
        final localPt = _unrotatePoint(
            e.localPosition, bbox.center, _rotateBaseRad);
        if (SelectionOverlayPainter.hitRotateHandle(bbox, localPt, zoom: z)) {
          ref.read(notebookProvider.notifier).pushUndo();
          _rotateStartBbox = bbox;
          _rotateStartAngle =
              SelectionOverlayPainter.angleAt(bbox, localPt);
          _rotateAccumRad = 0.0;
          setState(() {});
          return;
        }
        final h =
            SelectionOverlayPainter.hitHandle(bbox, localPt, zoom: z);
        if (h != null) {
          ref.read(notebookProvider.notifier).pushUndo();
          _scaleHandle = h;
          _scaleStartBbox = bbox;
          setState(() {});
          return;
        }
        if (SelectionOverlayPainter.inflatedBbox(bbox, zoom: z)
            .contains(localPt)) {
          ref.read(notebookProvider.notifier).pushUndo();
          _selectionDragging = true;
          _selectionDragStart = e.localPosition;
          _selectionDragLast = e.localPosition;
          setState(() {});
          return;
        }
      }
      ref.read(selectionProvider.notifier).clear();
      setState(() => _committedSelectRect = null);
    }
  }

  void _onDown(PointerDownEvent e) {
    if (!mounted) return;
    // Block all drawing/interaction while pinching (two-finger zoom/scroll).
    if (widget.isPinching) return;

    // S-Pen button held → temporary eraser (via spen_remote SDK or pointer kind).
    if (_isStylusButtonHeld(e) || ref.read(spenButtonHeldProvider)) {
      _tempErasing = true;
      _cursorNotifier.value = e.localPosition;
      _hitTestEraseAtPoint(e.localPosition, radius: ref.read(toolProvider).eraserAreaRadius);
      setState(() {});
      return;
    }
    _tempErasing = false;

    if (!InputGate(widget.inputMode).acceptsForDrawing(e)) {
      _handleNonDrawingDown(e);
      return;
    }
    _shiftHeld = HardwareKeyboard.instance.isShiftPressed;
    _cursorNotifier.value = e.localPosition;

    final at = _appTool();

    // Clear any active selection when the user clicks outside its bbox,
    // or when using any non-selection tool. Skip if the tap landed on the
    // floating selection action bar (sits 4..40 pt above the bbox).
    // Only act on selections belonging to THIS page.
    final z = _currentZoom();
    final sel = ref.read(selectionProvider);
    _maybeResetRotationBase(Object.hashAll(sel.strokeIds.toList()
      ..addAll(sel.shapeIds)
      ..addAll(sel.textIds)));
    if (sel.isNotEmpty && sel.pageId == widget.page.id) {
      final bbox = sel.bbox;
      final localPt = bbox == null
          ? e.localPosition
          : _unrotatePoint(e.localPosition, bbox.center, _rotateBaseRad);
      final insideBbox = bbox != null &&
          SelectionOverlayPainter.inflatedBbox(bbox, zoom: z)
              .contains(localPt);
      // text tool counts as a select-tool here so that clicking inside an
      // already-selected text box doesn't clear the selection before the
      // generic translate-drag check fires.
      final isSelectTool = at == AppTool.rectSelect ||
          at == AppTool.lasso ||
          at == AppTool.text;
      // Action-bar zone — must mirror the Positioned() in the build method.
      bool inActionBar = false;
      if (bbox != null) {
        final invZ = z == 0 ? 1.0 : 1.0 / z;
        final barW = 220 * invZ;
        final barH = 38 * invZ;
        // Lift the bar above the rotate handle (sits ~22 above bbox top)
        // so it doesn't cover it. Below-bbox placement adds the same gap.
        final barLeft = (bbox.center.dx - 110 * invZ)
            .clamp(4.0, widget.page.spec.widthPt - barW);
        final barTop = bbox.top < 70
            ? (bbox.bottom + 30 * invZ)
                .clamp(4.0, widget.page.spec.heightPt - barH - 2)
            : (bbox.top - 70 * invZ)
                .clamp(4.0, widget.page.spec.heightPt - barH - 2);
        final barRect = Rect.fromLTWH(barLeft, barTop, barW, barH);
        inActionBar = barRect.contains(e.localPosition);
      }
      if (inActionBar) {
        // Let the action-bar handle the gesture; don't clear or start a drag.
        return;
      }
      // Rotate-handle hit-test (rotate gesture) — checked before resize so
      // the small circle above the bbox isn't shadowed by the bbox itself.
      if (bbox != null &&
          SelectionOverlayPainter.hitRotateHandle(bbox, localPt, zoom: z)) {
        ref.read(notebookProvider.notifier).pushUndo();
        _rotateStartBbox = bbox;
        _rotateStartAngle =
            SelectionOverlayPainter.angleAt(bbox, localPt);
        _rotateAccumRad = 0.0;
        setState(() {});
        return;
      }
      // Resize-handle hit-test (scale gesture).
      if (bbox != null) {
        final h = SelectionOverlayPainter.hitHandle(bbox, localPt, zoom: z);
        if (h != null) {
          ref.read(notebookProvider.notifier).pushUndo();
          _scaleHandle = h;
          _scaleStartBbox = bbox;
          setState(() {});
          return;
        }
      }
      if (!isSelectTool || !insideBbox) {
        ref.read(selectionProvider.notifier).clear();
        setState(() {
          _committedLasso = const [];
          _committedSelectRect = null;
        });
      }
    }
    if (_isStrokeAppTool(at)) {
      // Shift + highlighter OR pen enters straight-line mode (no builder needed).
      _highlighterStraightLine =
          (at == AppTool.highlighter || at == AppTool.pen) && _shiftHeld;

      final toolState = ref.read(toolProvider);
      // Smoothing algorithm: only applies to pen tool.
      OneEuroFilter? xFilter, yFilter;
      if (at == AppTool.pen) {
        final algo = toolState.penSmoothingAlgo;
        if (algo == PenSmoothingAlgorithm.leash) {
          _strokeSmoothing = toolState.penLeashStrength;
          _leashMultiplier = 3.5;
          // No OneEuro — pass raw minCutoff/beta that means "no smoothing"
          xFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.5);
          yFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.5);
        } else {
          _strokeSmoothing = 0.0;
          _leashMultiplier = 0.0;
          final s = toolState.penOneEuroSmoothing;
          final b = toolState.penOneEuroBeta;
          xFilter = OneEuroFilter(
            minCutoff: 1.0 - 0.85 * s,
            beta: 0.5 - 0.49 * (1.0 - b),
          );
          yFilter = OneEuroFilter(
            minCutoff: 1.0 - 0.85 * s,
            beta: 0.5 - 0.49 * (1.0 - b),
          );
        }
      } else {
        _strokeSmoothing = 0.0;
        _leashMultiplier = 0.0;
      }
      final lineStyleIdx = at == AppTool.pen
          ? toolState.penLineStyle.clamp(0, 2)
          : 0;
      final lineStyle = LineStyle.values[lineStyleIdx];
      final dashGap = at == AppTool.pen ? toolState.penDashGap : 1.0;
      _builder = StrokeBuilder(
        pageId: widget.page.id,
        layerId: widget.activeLayerId,
        tool: widget.tool,
        colorArgb: widget.colorArgb,
        widthPt: widget.widthPt,
        opacity: widget.opacity,
        lineStyle: lineStyle,
        dashGap: dashGap,
        xFilter: xFilter,
        yFilter: yFilter,
      );
      _liveNotifier.value = const [];
      _strokeDownPos = e.localPosition;
      _movedPastTapThreshold = false;
      _leashP = e.localPosition; // leash starts at pen-down position
      _rawShapePts.clear();
      _lastTimerRawPt = null;
      _rawShapePts.add(StrokePoint(x: e.localPosition.dx, y: e.localPosition.dy));
      if (!_highlighterStraightLine) {
        // Add the pen-down position directly (leash starts here, so dist=0).
        _builder!.addRawPoint(
          x: e.localPosition.dx,
          y: e.localPosition.dy,
          pressure: e.kind == PointerDeviceKind.stylus ? e.pressure.clamp(0.0, 1.0) : 0.5,
          tiltX: e.tilt,
          tiltY: 0,
          tMs: e.timeStamp.inMilliseconds,
        );
      }
    } else if (at == AppTool.eraserArea) {
      _eraseAround(e.localPosition);
      setState(() {});
    } else if (_isDragRectAppTool(at) || at == AppTool.lasso) {
      // Text tool:
      //   - Tap on an existing box → if not currently editing, just select
      //     that text box (object-select). Tap again on the same selected
      //     box → enter edit mode.
      //   - While editing, tap outside → exit edit mode and select the
      //     previously editing box (no tool change, no new text spawn).
      if (at == AppTool.text) {
        final hit = _hitTestText(e.localPosition);
        if (hit != null) {
          // Already editing this one → keep editing.
          if (_editingTextBoxId == hit.id) return;
          // Already selected (but not editing) → defer between tap (enter
          // edit) and drag (translate). The decision is made in _onMove /
          // _onUp based on whether the pointer moves past a small slop.
          final curSel = ref.read(selectionProvider);
          if (curSel.textIds.length == 1 &&
              curSel.textIds.first == hit.id) {
            ref.read(notebookProvider.notifier).pushUndo();
            _textTapPendingEditId = hit.id;
            _selectionDragStart = e.localPosition;
            _selectionDragLast = e.localPosition;
            setState(() {});
            return;
          }
          // Otherwise: select the text box (no edit yet).
          // Re-measure so the selection bbox tracks the wrapped height
          // even if storage has a stale value.
          final fresh = withRemeasuredHeight(hit);
          if (fresh.bbox.maxY != hit.bbox.maxY) {
            widget.onTextChanged?.call(fresh);
          }
          final r = Rect.fromLTRB(
            fresh.bbox.minX, fresh.bbox.minY,
            fresh.bbox.maxX, fresh.bbox.maxY,
          );
          ref.read(selectionProvider.notifier).replace(SelectionState(
                textIds: {hit.id},
                bbox: r,
                pageId: widget.page.id,
              ));
          setState(() => _setEditingTextBoxId(null));
          FocusManager.instance.primaryFocus?.unfocus();
          return;
        }
        // Check if tap is within action-bar zone above editing box.
        final editingBox = _findEditingTextBox();
        if (editingBox != null) {
          final aboveZone = Rect.fromLTRB(
            editingBox.bbox.minX, editingBox.bbox.minY - 50,
            editingBox.bbox.minX + 220, editingBox.bbox.minY,
          );
          if (aboveZone.contains(e.localPosition)) return;
        }
        // Editing → tap outside should NOT spawn a new text box and should
        // NOT switch tools. Just exit edit mode and select the previously
        // editing text box so the user can drag / delete / duplicate it.
        if (_editingTextBoxId != null) {
          final selectedId = _editingTextBoxId!;
          final prevBox = _findTextById(selectedId);
          // Empty box → just exit edit; _setEditingTextBoxId will delete
          // it. Don't promote to a selection that points at a tombstone.
          if (prevBox == null || prevBox.text.trim().isEmpty) {
            FocusManager.instance.primaryFocus?.unfocus();
            ref.read(selectionProvider.notifier).clear();
            setState(() => _setEditingTextBoxId(null));
            return;
          }
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => _setEditingTextBoxId(null));
          // Compute bbox for this single text object so the selection
          // overlay + action bar appear above it.
          final box = _findTextById(selectedId);
          if (box != null) {
            final fresh = withRemeasuredHeight(box);
            if (fresh.bbox.maxY != box.bbox.maxY) {
              widget.onTextChanged?.call(fresh);
            }
            final r = Rect.fromLTRB(
              fresh.bbox.minX, fresh.bbox.minY,
              fresh.bbox.maxX, fresh.bbox.maxY,
            );
            ref.read(selectionProvider.notifier).replace(SelectionState(
                  textIds: {selectedId},
                  bbox: r,
                  pageId: widget.page.id,
                ));
          }
          return;
        }
        // Empty tap in text tool while a text-object is selected → just
        // clear the selection (don't spawn a new text box on this tap).
        final curSel = ref.read(selectionProvider);
        if (curSel.isNotEmpty && curSel.textIds.isNotEmpty) {
          ref.read(selectionProvider.notifier).clear();
          return;
        }
      }

      // If we have an active selection and the user clicks inside the bbox,
      // start a translate drag instead of a new selection. Allowed in
      // rectSelect / lasso / text tools.
      final sel = ref.read(selectionProvider);
      final bbox = sel.bbox;
      if ((at == AppTool.rectSelect ||
              at == AppTool.lasso ||
              at == AppTool.text) &&
          sel.isNotEmpty &&
          bbox != null &&
          SelectionOverlayPainter.inflatedBbox(bbox, zoom: _currentZoom())
              .contains(e.localPosition)) {
        // Push a single undo checkpoint for the whole drag.
        ref.read(notebookProvider.notifier).pushUndo();
        _selectionDragging = true;
        _selectionDragStart = e.localPosition;
        _selectionDragLast = e.localPosition;
        setState(() {});
        return;
      }

      // Clear any existing selection when starting a new drag.
      if (at == AppTool.rectSelect || at == AppTool.lasso) {
        ref.read(selectionProvider.notifier).clear();
      }

      _dragStart = e.localPosition;
      _dragCurrent = e.localPosition;
      _committedLasso = const [];
      _committedSelectRect = null;
      if (at == AppTool.lasso) {
        _lassoPoints
          ..clear()
          ..add(geom.Point2(e.localPosition.dx, e.localPosition.dy));
      }
      setState(() {});
    }
  }

  /// Returns the topmost non-deleted text box at [pos], or null.
  /// Extends the right edge by 12 px to cover the resize handle zone.
  TextBoxObject? _hitTestText(Offset pos) {
    // Find a candidate text under [pos], then verify nothing with a higher
    // z (later createdAt) covers the same point. Texts hidden behind a
    // later shape/stroke/text shouldn't be tappable.
    TextBoxObject? candidate;
    for (final layer in widget.layers.reversed) {
      if (!layer.visible || layer.locked) continue;
      final list = widget.textsByLayer[layer.id] ?? const <TextBoxObject>[];
      for (final t in list.reversed) {
        if (t.deleted) continue;
        final r = Rect.fromLTRB(
            t.bbox.minX, t.bbox.minY, t.bbox.maxX + 12, t.bbox.maxY);
        if (r.contains(pos)) { candidate = t; break; }
      }
      if (candidate != null) break;
    }
    if (candidate == null) return null;
    // Reject if a non-tape, later-z object covers the same point.
    for (final layer in widget.layers) {
      if (!layer.visible) continue;
      for (final s in widget.shapesByLayer[layer.id] ??
          const <ShapeObject>[]) {
        if (s.deleted) continue;
        if (!s.createdAt.isAfter(candidate.createdAt)) continue;
        // Outline-only shapes don't actually cover the text behind them —
        // skip those when checking occlusion.
        if (!s.filled) continue;
        final r = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
        if (r.contains(pos)) return null;
      }
      for (final s in widget.strokesByLayer[layer.id] ??
          const <Stroke>[]) {
        if (s.deleted || s.tool == ToolKind.tape) continue;
        if (!s.createdAt.isAfter(candidate.createdAt)) continue;
        final r = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY)
            .inflate(2);
        if (r.contains(pos)) return null;
      }
      for (final t2 in widget.textsByLayer[layer.id] ??
          const <TextBoxObject>[]) {
        if (t2.deleted || t2.id == candidate.id) continue;
        if (!t2.createdAt.isAfter(candidate.createdAt)) continue;
        final r = Rect.fromLTRB(t2.bbox.minX, t2.bbox.minY, t2.bbox.maxX, t2.bbox.maxY);
        if (r.contains(pos)) return null;
      }
    }
    return candidate;
  }

  TextBoxObject? _findEditingTextBox() {
    if (_editingTextBoxId == null) return null;
    return _findTextById(_editingTextBoxId!);
  }

  TextBoxObject? _findTextById(String id) {
    for (final layer in widget.layers) {
      final list = widget.textsByLayer[layer.id] ?? const <TextBoxObject>[];
      for (final t in list) {
        if (!t.deleted && t.id == id) return t;
      }
    }
    return null;
  }

  /// Build visual slices for [layer] in fixed z-order:
  ///   images → highlighter strokes → pen/shape strokes → text boxes
  List<Widget> _buildLayerSlices(Layer layer) {
    final allStrokes = (widget.strokesByLayer[layer.id] ?? const <Stroke>[])
        .where((s) => !s.deleted && s.tool != ToolKind.tape)
        .toList();
    final allShapes = (widget.shapesByLayer[layer.id] ?? const <ShapeObject>[])
        .where((s) => !s.deleted)
        .toList();
    final allTexts = (widget.textsByLayer[layer.id] ?? const <TextBoxObject>[])
        .where((t) => !t.deleted)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final allImages = (widget.imagesByLayer[layer.id] ?? const <ImageObject>[])
        .where((img) => !img.deleted)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final size = Size(widget.page.spec.widthPt, widget.page.spec.heightPt);
    final isTextTool = ref.watch(
        toolProvider.select((s) => s.activeTool == AppTool.text));
    final widgets = <Widget>[];

    // Pass 1 — images (below highlighter and pen strokes).
    for (final img in allImages) {
      widgets.add(IgnorePointer(
        child: _CanvasImage(image: img, layerOpacity: layer.opacity),
      ));
    }

    // Pass 2 — strokes + shapes via CombinedLayerPainter
    // (internally renders highlighters first, then shapes/pen strokes).
    if (allStrokes.isNotEmpty || allShapes.isNotEmpty) {
      widgets.add(RepaintBoundary(
        child: CustomPaint(
          painter: CombinedLayerPainter(
            shapes: List<ShapeObject>.unmodifiable(allShapes),
            strokes: List<Stroke>.unmodifiable(allStrokes),
            layerOpacity: layer.opacity,
          ),
          size: size,
        ),
      ));
    }

    // Pass 3 — text boxes (topmost, sorted by createdAt).
    for (final t in allTexts) {
      widgets.add(IgnorePointer(
        ignoring: !isTextTool,
        child: TextLayer(
          texts: [t],
          layerId: layer.id,
          editingBoxId:
              isTextTool && _editingTextBoxId == t.id ? t.id : null,
          onChanged: widget.onTextChanged,
        ),
      ));
    }

    return widgets;
  }

  void _onMove(PointerMoveEvent e) {
    if (!mounted) return;
    // Don't show brush cursor for finger/touch events.
    if (e.kind != PointerDeviceKind.touch) {
      _cursorNotifier.value = e.localPosition;
    }

    if (widget.isPinching) return;

    // S-Pen temporary eraser — only activates when no stroke is in progress.
    if (!_tempErasing && _builder == null &&
        (_isStylusButtonHeld(e) || ref.read(spenButtonHeldProvider))) {
      _tempErasing = true;
    }
    if (_tempErasing) {
      _cursorNotifier.value = e.localPosition;
      _hitTestEraseAtPoint(e.localPosition, radius: ref.read(toolProvider).eraserAreaRadius);
      setState(() {});
      return;
    }

    final at = _appTool();

    if (_isStrokeAppTool(at)) {
      if (_builder == null) return;
      if (_strokeDownPos != null && !_movedPastTapThreshold) {
        final d = (e.localPosition - _strokeDownPos!).distance;
        if (d > _tapMovementThreshold) _movedPastTapThreshold = true;
      }

      // Shift+highlighter: show a straight-line preview instead of freehand.
      if (_highlighterStraightLine && _strokeDownPos != null) {
        final snapped = _snapToConstrainedAngle(_strokeDownPos!, e.localPosition);
        _liveNotifier.value = [
          StrokePoint(x: _strokeDownPos!.dx, y: _strokeDownPos!.dy),
          StrokePoint(x: snapped.dx, y: snapped.dy),
        ];
        return;
      }

      _addStrokeSample(e);

      // EraserStroke: erase immediately on each move rather than waiting for
      // pointer-up, so strokes disappear as the eraser passes over them.
      if (at == AppTool.eraserStroke) {
        _hitTestEraseAtPoint(e.localPosition);
      }
    } else if (at == AppTool.eraserArea) {
      _eraseAround(e.localPosition);
      setState(() {});
    } else if (_isDragRectAppTool(at) || at == AppTool.lasso) {
      // Text tool: if a tap-vs-drag decision is pending, promote to drag
      // once the pointer moves far enough.
      if (_textTapPendingEditId != null && _selectionDragStart != null) {
        final moved =
            (e.localPosition - _selectionDragStart!).distance > _textDragSlop;
        if (moved) {
          _textTapPendingEditId = null;
          _selectionDragging = true;
          // Fall through to the drag-translate code below.
        } else {
          return; // still ambiguous; ignore tiny jitter
        }
      }
      if (_rotateStartBbox != null) {
        final sel = ref.read(selectionProvider);
        final center = _rotateStartBbox!.center;
        // Map the screen pointer through the persistent base rotation so
        // the angle math runs in the bbox's unrotated reference frame.
        final localPt =
            _unrotatePoint(e.localPosition, center, _rotateBaseRad);
        final newAngle =
            SelectionOverlayPainter.angleAt(_rotateStartBbox!, localPt);
        final delta = newAngle - _rotateStartAngle - _rotateAccumRad;
        if (delta.abs() > 1e-4) {
          ref.read(notebookProvider.notifier).rotateObjectsLive(
                widget.page.id,
                sel.strokeIds,
                sel.shapeIds,
                sel.textIds,
                center,
                delta,
              );
          _rotateAccumRad += delta;
          // Do NOT recompute selection.bbox during rotation — that would
          // re-align it to the (now-rotated) content's axis-aligned hull
          // and the overlay would visibly grow/shrink. Instead, keep the
          // start bbox and let the painter rotate the overlay by
          // _rotateAccumRad so the bbox visibly turns with the content.
          for (final layer in widget.layers) { _invalidateLayer(layer.id); }
          setState(() {});
        }
        return;
      }
      if (_scaleHandle != null && _scaleStartBbox != null) {
        final sel = ref.read(selectionProvider);
        final old = sel.bbox ?? _scaleStartBbox!;
        final newBbox = _bboxAfterHandleDrag(
            _scaleStartBbox!, old, _scaleHandle!, e.localPosition);
        if (newBbox.width > 1 && newBbox.height > 1) {
          ref.read(notebookProvider.notifier).scaleObjectsLive(
                widget.page.id, sel.strokeIds, sel.shapeIds, sel.textIds,
                old, newBbox,
              );
          ref.read(selectionProvider.notifier).updateBbox(newBbox);
          for (final layer in widget.layers) { _invalidateLayer(layer.id); }
          setState(() {});
        }
        return;
      }
      if (_selectionDragging && _selectionDragLast != null) {
        final delta = e.localPosition - _selectionDragLast!;
        _selectionDragLast = e.localPosition;
        final sel = ref.read(selectionProvider);
        // Translate objects live on every move so they follow the pointer.
        // Undo was already pushed at drag-start — no new entry per move.
        ref.read(notebookProvider.notifier).translateObjectsLive(
              widget.page.id, sel.strokeIds, sel.shapeIds, sel.textIds, delta,
            );
        if (sel.bbox != null) {
          ref.read(selectionProvider.notifier).updateBbox(
                sel.bbox!.translate(delta.dx, delta.dy),
              );
        }
        for (final layer in widget.layers) { _invalidateLayer(layer.id); }
        setState(() {});
        return;
      }
      if (_dragStart == null) return;
      final prev = _dragCurrent;
      _dragCurrent = e.localPosition;
      if (at == AppTool.lasso) {
        _lassoPoints.add(geom.Point2(e.localPosition.dx, e.localPosition.dy));
      }
      // Shape tools: auto-regularize when the pointer holds still.
      if (_isShapeTool(at)) {
        final moved = prev == null
            ? true
            : (e.localPosition - prev).distance > _stillMoveSlop;
        if (moved) {
          if (_autoRegularize) {
            setState(() {
              _autoRegularize = false;
              _autoRegularizeSince = null;
            });
          }
          _stillTimer?.cancel();
          _stillTimer = Timer(_stillDelay, () {
            if (!mounted) return;
            setState(() {
              _autoRegularize = true;
              _autoRegularizeSince = DateTime.now();
            });
          });
        }
      }
      setState(() {});
    }
  }

  bool _isShapeTool(AppTool t) =>
      t == AppTool.shapeRect ||
      t == AppTool.shapeEllipse ||
      t == AppTool.shapeTriangle ||
      t == AppTool.shapeDiamond ||
      t == AppTool.shapeArrow ||
      t == AppTool.shapeLine;

  /// Compute the new bbox when [handle] is dragged to [pointer].
  ///
  /// Corner handles (tl/tr/bl/br) apply uniform (aspect-ratio-preserving)
  /// scaling by projecting [pointer] onto the diagonal from the anchor corner
  /// to the dragged corner of [startBbox]. This means dragging a corner always
  /// scales proportionally — no stretching.
  ///
  /// Edge handles (tc/bc/ml/mr) move only one side; they use [currentBbox] as
  /// the reference so the opposite side stays put while the live bbox changes.
  static Rect _bboxAfterHandleDrag(
      Rect startBbox, Rect currentBbox, SelectionHandle handle, Offset pointer) {
    switch (handle) {
      // ── Corner handles: uniform (proportional) scale ────────────────────
      case SelectionHandle.tl:
      case SelectionHandle.tr:
      case SelectionHandle.bl:
      case SelectionHandle.br:
        return _proportionalCornerDrag(startBbox, handle, pointer);

      // ── Edge handles: one-axis stretch (existing behaviour) ─────────────
      case SelectionHandle.tc:
        return Rect.fromLTRB(currentBbox.left, pointer.dy,
            currentBbox.right, currentBbox.bottom);
      case SelectionHandle.bc:
        return Rect.fromLTRB(currentBbox.left, currentBbox.top,
            currentBbox.right, pointer.dy);
      case SelectionHandle.ml:
        return Rect.fromLTRB(pointer.dx, currentBbox.top,
            currentBbox.right, currentBbox.bottom);
      case SelectionHandle.mr:
        return Rect.fromLTRB(currentBbox.left, currentBbox.top,
            pointer.dx, currentBbox.bottom);
    }
  }

  /// Uniform scale for corner handles.
  ///
  /// The anchor is the corner opposite [handle] on [start]. We project the
  /// pointer (relative to the anchor) onto the diagonal vector to derive a
  /// single scale factor, then apply it to both axes.
  static Rect _proportionalCornerDrag(
      Rect start, SelectionHandle handle, Offset pointer) {
    // (ax, ay) = anchor corner (fixed), (cx, cy) = original dragged corner.
    final (ax, ay, cx, cy) = switch (handle) {
      SelectionHandle.br => (start.left,  start.top,    start.right,  start.bottom),
      SelectionHandle.bl => (start.right, start.top,    start.left,   start.bottom),
      SelectionHandle.tr => (start.left,  start.bottom, start.right,  start.top),
      SelectionHandle.tl => (start.right, start.bottom, start.left,   start.top),
      _ => throw StateError('not a corner handle'),
    };

    final dx = cx - ax;
    final dy = cy - ay;
    final diagLen2 = dx * dx + dy * dy;
    if (diagLen2 < 1e-6) return start;

    // Project pointer-relative-to-anchor onto the diagonal → scalar scale.
    final scale = ((pointer.dx - ax) * dx + (pointer.dy - ay) * dy) / diagLen2;

    // New dragged corner = anchor + scale × original_diagonal.
    return Rect.fromPoints(Offset(ax, ay), Offset(ax + dx * scale, ay + dy * scale));
  }

  @override
  void dispose() {
    _stillTimer?.cancel();
    _shapeHoldTimer?.cancel();
    _liveNotifier.dispose();
    _cursorNotifier.dispose();
    super.dispose();
  }

  void _onUp(PointerUpEvent e) {
    if (!mounted) return;
    if (_tempErasing) {
      _tempErasing = false;
      setState(() {});
      return;
    }
    if (widget.isPinching) return;
    final at = _appTool();
    if (_isStrokeAppTool(at)) {
      // ── Tape tap-to-toggle ─────────────────────────────────────────
      if (at == AppTool.tape &&
          !_movedPastTapThreshold &&
          _strokeDownPos != null) {
        _hitTestTapeToggle(_strokeDownPos!);
        _builder = null;
        _liveNotifier.value = const [];
        _strokeDownPos = null;
        setState(() {});
        return;
      }

      // ── Shift + highlighter → commit a straight line ───────────────
      if (_highlighterStraightLine && _strokeDownPos != null) {
        final start = _strokeDownPos!;
        final snapped = _snapToConstrainedAngle(start, e.localPosition);
        _builder = null;
        _liveNotifier.value = const [];
        _strokeDownPos = null;
        _highlighterStraightLine = false;
        if ((snapped - start).distance > 4) {
          final pts = [
            StrokePoint(x: start.dx, y: start.dy),
            StrokePoint(x: snapped.dx, y: snapped.dy),
          ];
          final stroke = Stroke(
            id: newId(),
            pageId: widget.page.id,
            layerId: widget.activeLayerId,
            // Use the actual active tool kind so pen lines are stored as pen
            // strokes and highlighter lines as highlighter strokes.
            tool: at == AppTool.pen ? ToolKind.pen : ToolKind.highlighter,
            colorArgb: widget.colorArgb,
            widthPt: widget.widthPt,
            opacity: widget.opacity,
            points: pts,
            bbox: Bbox(
              minX: math.min(start.dx, snapped.dx),
              minY: math.min(start.dy, snapped.dy),
              maxX: math.max(start.dx, snapped.dx),
              maxY: math.max(start.dy, snapped.dy),
            ),
            createdAt: DateTime.now().toUtc(),
          );
          _invalidateLayer(widget.activeLayerId);
          widget.onStrokeCommitted(stroke);
        }
        setState(() {});
        return;
      }

      // ── EraserStroke: already erased on move; just clean up ────────
      if (at == AppTool.eraserStroke) {
        _builder = null;
        _liveNotifier.value = const [];
        _strokeDownPos = null;
        setState(() {});
        return;
      }

      // ── Normal stroke tools ────────────────────────────────────────
      _shapeHoldTimer?.cancel();
      _shapeHoldTimer = null;

      final b = _builder;
      _builder = null;
      _liveNotifier.value = const [];
      _strokeDownPos = null;
      _leashP = null;

      // "Draw and hold" snap: commit the recognized perfect shape instead.
      final snapPts = _recognizedShapePts;
      _recognizedShapePts = null;
      _rawShapePts.clear();
      _lastTimerRawPt = null;

      if (b == null) {
        setState(() {});
        return;
      }

      if (snapPts != null && snapPts.length >= 2) {
        final snapToolKind = at == AppTool.highlighter
            ? ToolKind.highlighter
            : at == AppTool.tape
                ? ToolKind.tape
                : ToolKind.pen;
        final snapStroke = Stroke(
          id: newId(),
          pageId: widget.page.id,
          layerId: widget.activeLayerId,
          tool: snapToolKind,
          colorArgb: widget.colorArgb,
          widthPt: widget.widthPt,
          opacity: widget.opacity,
          lineStyle: b?.lineStyle ?? LineStyle.solid,
          dashGap: b?.dashGap ?? 1.0,
          points: List.unmodifiable(snapPts),
          bbox: Bbox.fromPoints(snapPts),
          createdAt: DateTime.now().toUtc(),
        );
        _invalidateLayer(widget.activeLayerId);
        widget.onStrokeCommitted(snapStroke);
        setState(() {});
        return;
      }

      final stroke = b.finish();
      if (stroke != null) {
        _invalidateLayer(stroke.layerId);
        widget.onStrokeCommitted(stroke);
      }
      setState(() {});
    } else if (at == AppTool.eraserArea) {
      setState(() {});
    } else if (_isDragRectAppTool(at) || at == AppTool.lasso) {
      // Text tool deferred decision — no drag occurred → treat as a tap
      // and enter edit mode for the previously-selected text box.
      if (_textTapPendingEditId != null) {
        final id = _textTapPendingEditId!;
        _textTapPendingEditId = null;
        _selectionDragStart = null;
        _selectionDragLast = null;
        ref.read(selectionProvider.notifier).clear();
        setState(() => _setEditingTextBoxId(id));
        return;
      }
      if (_selectionDragging) {
        _commitSelectionTranslate();
        _selectionDragging = false;
        _selectionDragStart = null;
        _selectionDragLast = null;
        setState(() {});
        return;
      }
      // Scale gesture finishes here — nothing further to commit (changes
      // were applied live).
      if (_scaleHandle != null) {
        _scaleHandle = null;
        _scaleStartBbox = null;
        setState(() {});
        return;
      }
      // Rotate gesture finishes — points were already mutated live.
      if (_rotateStartBbox != null) {
        // Fold this drag's rotation into the persistent base so the bbox
        // overlay keeps showing the rotated orientation after release.
        _rotateBaseRad += _rotateAccumRad;
        _rotateStartBbox = null;
        _rotateStartAngle = 0.0;
        _rotateAccumRad = 0.0;
        setState(() {});
        return;
      }
      _commitDragGesture();
      _dragStart = null;
      _dragCurrent = null;
      _lassoPoints.clear();
      _stillTimer?.cancel();
      _stillTimer = null;
      _autoRegularize = false;
      _autoRegularizeSince = null;
      setState(() {});
    }
  }

  void _commitSelectionTranslate() {
    // Translation is applied live on each _onMove; nothing more to do on commit.
  }

  void _addStrokeSample(PointerEvent e) {
    final b = _builder;
    if (b == null) return;

    final M = e.localPosition;
    final P0 = _leashP ?? M;

    // Leash = 0 when smoothing=0 (raw passthrough), scales up to _leashMaxPx.
    final zoom = widget.zoomNotifier?.value ?? 1.0;
    final leash = _leashMaxPx * _strokeSmoothing * _leashMultiplier / zoom;

    final dx = M.dx - P0.dx;
    final dy = M.dy - P0.dy;
    final dist2 = dx * dx + dy * dy;

    Offset P;
    if (leash < 0.5 || dist2 > leash * leash) {
      // smoothing=0: P=M (raw). Otherwise: pull P to leash distance from M.
      if (leash < 0.5) {
        P = M;
      } else {
        final dist = math.sqrt(dist2);
        P = Offset(M.dx - dx / dist * leash, M.dy - dy / dist * leash);
      }
    } else {
      return; // M hasn't moved past the leash threshold; P stays put.
    }

    _leashP = P;
    b.addRawPoint(
      x: P.dx,
      y: P.dy,
      pressure: e.kind == PointerDeviceKind.stylus ? e.pressure.clamp(0.0, 1.0) : 0.5,
      tiltX: e.tilt,
      tiltY: 0,
      tMs: e.timeStamp.inMilliseconds,
    );
    // Once a snap has fired, keep showing the snapped preview — don't let
    // subsequent raw points clobber it (the commit at _onUp already uses
    // _recognizedShapePts, but the user must see stable visual feedback).
    if (_recognizedShapePts == null) {
      _liveNotifier.value = List.unmodifiable(b.points);
    }

    // Capture the raw pointer position (pre-leash) for shape recognition.
    _rawShapePts.add(StrokePoint(x: M.dx, y: M.dy));

    // Reset hold timer only when the pointer has moved meaningfully.
    // Without this gate, tools without leash (highlighter/tape) reset the
    // timer on every stylus jitter event and the 600ms hold never fires.
    if (_recognizedShapePts == null) {
      const stillTolPx = 1.5;
      var moved = true;
      if (_lastTimerRawPt != null) {
        final ddx = M.dx - _lastTimerRawPt!.dx;
        final ddy = M.dy - _lastTimerRawPt!.dy;
        if (ddx * ddx + ddy * ddy < stillTolPx * stillTolPx) moved = false;
      }
      if (moved) {
        _lastTimerRawPt = M;
        _shapeHoldTimer?.cancel();
        if (_rawShapePts.length >= 8) {
          _shapeHoldTimer = Timer(_shapeHoldDuration, _trySnapToShape);
        }
      }
    }
  }

  void _trySnapToShape() {
    if (!mounted) return;
    final b = _builder;
    if (b == null || _rawShapePts.length < 8) return;
    final at = _appTool();
    List<StrokePoint>? snapped;

    if (at == AppTool.pen) {
      // Pen: try closed shapes + line first; fall back to smooth curve.
      final result = recognizeStroke(_rawShapePts);
      if (result != null) {
        snapped = result.points;
      }
    }
    // Pen (fallback), Highlighter, Tape: try line → smooth curve.
    if (snapped == null &&
        (at == AppTool.pen ||
            at == AppTool.highlighter ||
            at == AppTool.tape)) {
      final result = recognizeLineOrCurve(_rawShapePts);
      if (result != null) {
        var pts = result.points;
        // Straight-line result: also apply ±8° axis snap (anchored at the
        // first point) so near-horizontal/vertical lines render as exact.
        if (result.isStraight && pts.length >= 2) {
          final start = Offset(pts.first.x, pts.first.y);
          final end = Offset(pts.last.x, pts.last.y);
          final snappedEnd = _snapToConstrainedAngle(start, end);
          if (snappedEnd != end) {
            pts = [
              pts.first,
              StrokePoint(x: snappedEnd.dx, y: snappedEnd.dy),
            ];
          }
        }
        snapped = pts;
      }
    }

    if (snapped != null) {
      setState(() {
        _recognizedShapePts = snapped;
        _liveNotifier.value = List.unmodifiable(snapped!);
      });
    }
  }

  // Find any tape stroke under the tap point and toggle its reveal state.
  // Hit zone = stroke width / 2 + small tolerance.
  void _hitTestTapeToggle(Offset tap) {
    for (final layer in widget.layers.reversed) {
      if (!layer.visible || layer.locked) continue;
      final list = widget.strokesByLayer[layer.id] ?? const <Stroke>[];
      for (final s in list.reversed) {
        if (s.deleted || s.tool != ToolKind.tape) continue;
        if (!_pointInBbox(tap, s.bbox, s.widthPt)) continue;
        final r = (s.widthPt / 2) + 4;
        for (var i = 1; i < s.points.length; i++) {
          final p1 = s.points[i - 1], p2 = s.points[i];
          if (geom.circleIntersectsSegment(
              tap.dx, tap.dy, r, p1.x, p1.y, p2.x, p2.y)) {
            _toggleTape(s.id, layer.id);
            return;
          }
        }
      }
    }
  }

  bool _pointInBbox(Offset p, Bbox b, double pad) {
    return p.dx >= b.minX - pad &&
        p.dx <= b.maxX + pad &&
        p.dy >= b.minY - pad &&
        p.dy <= b.maxY + pad;
  }

  /// Standard (area) eraser. Hit zone matches the on-screen cursor radius
  /// exactly (no stroke-width bonus) so the user erases what they see.
  /// Strokes are split at the eraser-circle boundary so only the part
  /// inside the disc is removed (tape/highlighter still go whole).
  void _eraseAround(Offset center) {
    final r = effectiveEraserRadius(ref.read(toolProvider));
    final r2 = r * r;
    final deletes = <String>{};
    final adds = <Stroke>[];

    bool isInside(StrokePoint p) {
      final dx = p.x - center.dx, dy = p.y - center.dy;
      return dx * dx + dy * dy <= r2;
    }

    // Compute the up-to-two parametric intersections (t in [0,1]) of the
    // segment p1→p2 with the eraser circle. Returns sorted ascending.
    List<double> segCircleParams(StrokePoint p1, StrokePoint p2) {
      final dx = p2.x - p1.x, dy = p2.y - p1.y;
      final fx = p1.x - center.dx, fy = p1.y - center.dy;
      final a = dx * dx + dy * dy;
      if (a == 0) return const [];
      final b = 2 * (fx * dx + fy * dy);
      final c = fx * fx + fy * fy - r2;
      final disc = b * b - 4 * a * c;
      if (disc < 0) return const [];
      final sq = math.sqrt(disc);
      final t1 = (-b - sq) / (2 * a);
      final t2 = (-b + sq) / (2 * a);
      final out = <double>[];
      if (t1 >= 0 && t1 <= 1) out.add(t1);
      if (t2 >= 0 && t2 <= 1 && (out.isEmpty || (t2 - t1).abs() > 1e-6)) {
        out.add(t2);
      }
      return out;
    }

    StrokePoint lerp(StrokePoint a, StrokePoint b, double t) {
      return StrokePoint(
        x: a.x + (b.x - a.x) * t,
        y: a.y + (b.y - a.y) * t,
        pressure: a.pressure + (b.pressure - a.pressure) * t,
      );
    }

    for (final layer in widget.layers) {
      if (layer.locked) continue;
      final list = widget.strokesByLayer[layer.id] ?? const <Stroke>[];
      for (final s in list) {
        if (s.deleted) continue;
        if (s.points.isEmpty) continue;

        // Quick reject — any segment intersect the disc?
        bool any = false;
        if (s.points.length == 1) {
          any = isInside(s.points.first);
        } else {
          for (var i = 1; i < s.points.length; i++) {
            if (geom.circleIntersectsSegment(
                center.dx, center.dy, r,
                s.points[i - 1].x, s.points[i - 1].y,
                s.points[i].x, s.points[i].y)) {
              any = true;
              break;
            }
          }
        }
        if (!any) continue;

        // Tape / highlighter — whole-stroke delete.
        final wholeStroke = s.tool == ToolKind.tape ||
            s.tool == ToolKind.highlighter;
        if (wholeStroke) {
          deletes.add(s.id);
          continue;
        }

        // Walk segments, splitting at every circle crossing.
        final runs = <List<StrokePoint>>[];
        var cur = <StrokePoint>[];
        if (!isInside(s.points.first)) cur.add(s.points.first);

        for (var i = 1; i < s.points.length; i++) {
          final a = s.points[i - 1];
          final b = s.points[i];
          final aIn = isInside(a);
          final bIn = isInside(b);
          if (!aIn && !bIn) {
            // Segment may still cross the disc (both endpoints outside).
            final ts = segCircleParams(a, b);
            if (ts.length == 2) {
              // Enter at t1, exit at t2 — close current run at entry,
              // start new run at exit.
              cur.add(lerp(a, b, ts[0]));
              if (cur.length >= 2) runs.add(cur);
              cur = <StrokePoint>[lerp(a, b, ts[1]), b];
            } else {
              cur.add(b);
            }
          } else if (aIn && !bIn) {
            // Exiting the disc — start a new run from the boundary.
            final ts = segCircleParams(a, b);
            final tExit = ts.isNotEmpty ? ts.last : 1.0;
            cur = <StrokePoint>[lerp(a, b, tExit), b];
          } else if (!aIn && bIn) {
            // Entering the disc — close current run at the boundary.
            final ts = segCircleParams(a, b);
            final tEnter = ts.isNotEmpty ? ts.first : 0.0;
            cur.add(lerp(a, b, tEnter));
            if (cur.length >= 2) runs.add(cur);
            cur = <StrokePoint>[];
          } else {
            // Both inside — drop.
          }
        }
        if (cur.length >= 2) runs.add(cur);

        deletes.add(s.id);
        for (final run in runs) {
          adds.add(s.copyWith(
            id: newId(),
            points: run,
            bbox: Bbox.fromPoints(run),
            createdAt: s.createdAt,
            rev: 0,
            deleted: false,
          ));
        }
      }
    }
    if (deletes.isEmpty && adds.isEmpty) return;
    ref
        .read(notebookProvider.notifier)
        .replaceStrokes(widget.page.id, deletes, adds);
    for (final layer in widget.layers) {
      _invalidateLayer(layer.id);
    }
  }

  /// Per-point stroke eraser: erases any stroke whose segments are within
  // Fixed hit-test radius in screen pixels — stays the same touch target regardless of zoom.
  static const _kStrokeEraserScreenPx = 24.0;

  /// Stroke eraser: zoom-aware radius (screenPx / zoom → page coords).
  /// Area eraser: user-set slider value in page coords.
  double get _eraserStrokeRadius {
    final s = ref.read(toolProvider);
    if (s.activeTool == AppTool.eraserStroke) {
      final zoom = widget.zoomNotifier?.value ?? 1.0;
      return _kStrokeEraserScreenPx / zoom;
    }
    return s.eraserAreaRadius;
  }

  void _hitTestEraseAtPoint(Offset pos, {double? radius}) {
    final eraseR = radius ?? _eraserStrokeRadius;
    final strokeHits = <String>{};
    final objectHits = <String>{};
    for (final layer in widget.layers) {
      if (layer.locked) continue;
      // Strokes
      if (widget.onEraseStrokes != null) {
        final list = widget.strokesByLayer[layer.id] ?? const <Stroke>[];
        stroke:
        for (final s in list) {
          if (s.deleted) continue;
          if (s.points.length < 2) continue;
          // Effective hit radius = eraser radius + half the stroke's
          // own width so wide strokes (tape, fat highlighters) are hit
          // anywhere across their visible body, not just on the centre.
          final hitR = eraseR + s.widthPt / 2;
          for (var i = 1; i < s.points.length; i++) {
            final p1 = s.points[i - 1], p2 = s.points[i];
            if (geom.circleIntersectsSegment(
                pos.dx, pos.dy, hitR,
                p1.x, p1.y, p2.x, p2.y)) {
              strokeHits.add(s.id);
              continue stroke;
            }
          }
        }
      }
      // Shapes — hit-test bounding box inflated by eraser radius
      if (widget.onEraseObjects != null) {
        final shapes = widget.shapesByLayer[layer.id] ?? const <ShapeObject>[];
        for (final sh in shapes) {
          if (sh.deleted) continue;
          final r = Rect.fromLTRB(sh.bbox.minX, sh.bbox.minY, sh.bbox.maxX, sh.bbox.maxY)
              .inflate(eraseR);
          if (r.contains(pos)) objectHits.add(sh.id);
        }
      }
    }
    if (strokeHits.isNotEmpty) {
      widget.onEraseStrokes!(strokeHits);
    }
    if (objectHits.isNotEmpty) {
      widget.onEraseObjects!(objectHits);
    }
    if (strokeHits.isNotEmpty || objectHits.isNotEmpty) {
      for (final layer in widget.layers) {
        _invalidateLayer(layer.id);
      }
    }
  }

  /// Snap [end] to the nearest 45° angle from [start] (0°, 45°, 90°, …).
  /// Snap a straight line to the x- or y-axis when its slope falls within
  /// ±5° of horizontal or vertical. The line is anchored at [start] so the
  /// first-pressed point stays put. Lines outside the tolerance window are
  /// returned unchanged so the user's freeform angle is preserved.
  Offset _snapToConstrainedAngle(Offset start, Offset end) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1) return end;
    // Angle from +x axis, in degrees, normalised to [0, 90] regardless of
    // direction — that's what determines "near horizontal" vs "near vertical".
    final rawDeg = math.atan2(dy, dx) * 180 / math.pi;
    final absDeg = rawDeg.abs(); // 0..180
    final fold = absDeg > 90 ? 180 - absDeg : absDeg; // 0..90
    const tol = 8.0;
    if (fold <= tol) {
      // Near horizontal — keep first point's y.
      return Offset(end.dx, start.dy);
    }
    if (fold >= 90 - tol) {
      // Near vertical — keep first point's x.
      return Offset(start.dx, end.dy);
    }
    return end;
  }

  bool _isLassoTool() => ref.read(toolProvider).activeTool == AppTool.lasso;

  void _commitDragGesture() {
    final ds = _dragStart, dc = _dragCurrent;
    if (ds == null || dc == null) return;
    final tool = ref.read(toolProvider).activeTool;
    final settings = ref.read(toolProvider);
    final rect = Rect.fromPoints(ds, dc);
    if (rect.width.abs() < 4 && rect.height.abs() < 4 &&
        tool != AppTool.text && tool != AppTool.lasso) {
      return;
    }

    rec.ShapeRect normalized = rec.ShapeRect(
      math.min(rect.left, rect.right),
      math.min(rect.top, rect.bottom),
      math.max(rect.left, rect.right),
      math.max(rect.top, rect.bottom),
    );

    switch (tool) {
      case AppTool.shapeRect:
      case AppTool.shapeEllipse:
      case AppTool.shapeTriangle:
      case AppTool.shapeDiamond:
      case AppTool.shapeArrow:
      case AppTool.shapeLine:
        // Auto-regularize commits only when the pointer was held still for
        // at least the snap-hold grace period after the snap fired —
        // otherwise the user lifted off too early and likely intended the
        // free shape.
        final stillLongEnough = _autoRegularize &&
            _autoRegularizeSince != null &&
            DateTime.now().difference(_autoRegularizeSince!) >= _snapHoldGrace;
        // Read shift live so pressing it mid-drag still snaps the result.
        final shiftLive = HardwareKeyboard.instance.isShiftPressed;
        if (shiftLive || stillLongEnough) {
          // Signed-snap so the regularized shape preserves the drag
          // direction (up-left → square going up-left), not always
          // anchored at top-left.
          final r = _signedSquareFromDrag(ds, dc);
          normalized = rec.ShapeRect(
            math.min(r.left, r.right),
            math.min(r.top, r.bottom),
            math.max(r.left, r.right),
            math.max(r.top, r.bottom),
          );
        }
        final domKind = tool == AppTool.shapeRect
            ? ShapeKind.rectangle
            : tool == AppTool.shapeEllipse
                ? ShapeKind.ellipse
                : tool == AppTool.shapeDiamond
                    ? ShapeKind.diamond
                    : tool == AppTool.shapeArrow
                        ? ShapeKind.arrow
                        : tool == AppTool.shapeLine
                            ? ShapeKind.line
                            : ShapeKind.triangle;
        final isArrowOrLine = tool == AppTool.shapeArrow ||
            tool == AppTool.shapeLine;
        final s = ShapeObject(
          id: newId(),
          pageId: widget.page.id,
          layerId: widget.activeLayerId,
          shape: domKind,
          bbox: Bbox(
            minX: normalized.minX,
            minY: normalized.minY,
            maxX: normalized.maxX,
            maxY: normalized.maxY,
          ),
          colorArgb: settings.penColor,
          strokeWidthPt: settings.penWidth,
          filled: settings.shapeFilled,
          fillColorArgb: settings.shapeFilled ? settings.shapeFillColorArgb : null,
          regularized: shiftLive || stillLongEnough,
          arrowFlipX: isArrowOrLine && dc.dx < ds.dx,
          arrowFlipY: isArrowOrLine && dc.dy < ds.dy,
          createdAt: DateTime.now().toUtc(),
        );
        widget.onShapeCommitted?.call(s);
        _invalidateLayer(widget.activeLayerId);
      case AppTool.text:
        final t = TextBoxObject(
          id: newId(),
          pageId: widget.page.id,
          layerId: widget.activeLayerId,
          bbox: Bbox(
            minX: normalized.minX,
            minY: normalized.minY,
            maxX: math.max(normalized.maxX, normalized.minX + 120),
            maxY: math.max(normalized.maxY, normalized.minY + 30),
          ),
          colorArgb: settings.textColor,
          fontSizePt: settings.textFontSizePt,
          fontWeight: settings.textFontWeight,
          fontFamily: settings.textFontFamily,
          italic: settings.textItalic,
          textAlign: settings.textAlign,
          createdAt: DateTime.now().toUtc(),
        );
        widget.onTextCommitted?.call(t);
        setState(() => _setEditingTextBoxId(t.id));
      case AppTool.lasso:
        if (_lassoPoints.length > 2) {
          final polygon = List<geom.Point2>.unmodifiable(_lassoPoints);
          _computeSelectionFromLasso(polygon);
          // Clear lasso outline — bbox overlay shows the selection.
          setState(() {
            _committedLasso = const [];
            _committedSelectRect = null;
          });
        } else if (_dragStart != null) {
          // Tap (no drag) → hit-test the topmost object at the tap point
          // and select it. Lets the lasso tool double as a click-to-select.
          _selectTopmostAt(_dragStart!);
          setState(() {
            _committedLasso = const [];
            _committedSelectRect = null;
          });
        }
      case AppTool.rectSelect:
        if (rect.width.abs() >= 4 || rect.height.abs() >= 4) {
          setState(() {
            // Clear the drag-rect outline; the selection bbox overlay
            // takes over from here.
            _committedSelectRect = null;
            _committedLasso = const [];
          });
          _computeSelectionFromRect(rect);
        }
      default:
        break;
    }
  }

  List<Stroke> _allStrokes() => widget.layers
      .expand((l) => widget.strokesByLayer[l.id] ?? const <Stroke>[])
      .toList();

  List<ShapeObject> _allShapes() => widget.layers
      .expand((l) => widget.shapesByLayer[l.id] ?? const <ShapeObject>[])
      .toList();

  List<TextBoxObject> _allTexts() => widget.layers
      .expand((l) => widget.textsByLayer[l.id] ?? const <TextBoxObject>[])
      .toList();

  void _computeSelectionFromRect(Rect rect) {
    ref.read(selectionProvider.notifier).setFromRect(
          rect: rect,
          strokes: _allStrokes(),
          shapes: _allShapes(),
          texts: _allTexts(),
          pageId: widget.page.id,
        );
  }

  /// Select the topmost (highest createdAt) object that contains [pos].
  /// Used by the lasso tool to act as a click-to-select.
  void _selectTopmostAt(Offset pos) {
    final entries = <(DateTime, String, Rect, int)>[]; // 0=stroke 1=shape 2=text
    for (final layer in widget.layers) {
      if (layer.locked) continue;
      for (final s in widget.strokesByLayer[layer.id] ?? const <Stroke>[]) {
        if (s.deleted) continue;
        if (s.tool == ToolKind.tape) continue;
        final r = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY)
            .inflate(4);
        if (r.contains(pos)) entries.add((s.createdAt, s.id, r, 0));
      }
      for (final s in widget.shapesByLayer[layer.id] ?? const <ShapeObject>[]) {
        if (s.deleted) continue;
        final r = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
        if (r.contains(pos)) entries.add((s.createdAt, s.id, r, 1));
      }
      for (final t in widget.textsByLayer[layer.id] ?? const <TextBoxObject>[]) {
        if (t.deleted) continue;
        final r = Rect.fromLTRB(t.bbox.minX, t.bbox.minY, t.bbox.maxX, t.bbox.maxY);
        if (r.contains(pos)) entries.add((t.createdAt, t.id, r, 2));
      }
    }
    if (entries.isEmpty) {
      ref.read(selectionProvider.notifier).clear();
      return;
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1)); // topmost first
    final hit = entries.first;
    final ids = <String>{hit.$2};
    ref.read(selectionProvider.notifier).replace(SelectionState(
          strokeIds: hit.$4 == 0 ? ids : const {},
          shapeIds: hit.$4 == 1 ? ids : const {},
          textIds: hit.$4 == 2 ? ids : const {},
          bbox: hit.$3,
          pageId: widget.page.id,
        ));
  }

  void _computeSelectionFromLasso(List<geom.Point2> polygon) {
    ref.read(selectionProvider.notifier).setFromLasso(
          polygon: polygon,
          strokes: _allStrokes(),
          shapes: _allShapes(),
          texts: _allTexts(),
          pageId: widget.page.id,
        );
  }

  void _deleteSelection() {
    final sel = ref.read(selectionProvider);
    if (sel.isEmpty) return;
    ref.read(notebookProvider.notifier).deleteObjects(
          widget.page.id,
          sel.allIds,
        );
    ref.read(selectionProvider.notifier).clear();
    setState(() {
      _committedLasso = const [];
      _committedSelectRect = null;
    });
    for (final layer in widget.layers) {
      _invalidateLayer(layer.id);
    }
  }

  void _reorderSelection(int direction) {
    final sel = ref.read(selectionProvider);
    if (sel.isEmpty) return;
    ref.read(notebookProvider.notifier)
        .reorderObjects(widget.page.id, sel.allIds, direction);
    for (final layer in widget.layers) {
      _invalidateLayer(layer.id);
    }
    setState(() {});
  }

  void _duplicateSelection() {
    final sel = ref.read(selectionProvider);
    if (sel.isEmpty) return;
    final newIds = ref
        .read(notebookProvider.notifier)
        .duplicateObjects(widget.page.id, sel.allIds);
    for (final layer in widget.layers) {
      _invalidateLayer(layer.id);
    }
    // Reselect the duplicates so the user can immediately move/style them.
    final notebook = ref.read(notebookProvider);
    final newStrokes = <String>{};
    final newShapes = <String>{};
    final newTexts = <String>{};
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void grow(double x1, double y1, double x2, double y2) {
      if (x1 < minX) minX = x1;
      if (y1 < minY) minY = y1;
      if (x2 > maxX) maxX = x2;
      if (y2 > maxY) maxY = y2;
    }

    for (final s in notebook.strokesByPage[widget.page.id] ?? const <Stroke>[]) {
      if (newIds.contains(s.id)) {
        newStrokes.add(s.id);
        grow(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      }
    }
    for (final s in notebook.shapesByPage[widget.page.id] ??
        const <ShapeObject>[]) {
      if (newIds.contains(s.id)) {
        newShapes.add(s.id);
        grow(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      }
    }
    for (final t in notebook.textsByPage[widget.page.id] ??
        const <TextBoxObject>[]) {
      if (newIds.contains(t.id)) {
        newTexts.add(t.id);
        grow(t.bbox.minX, t.bbox.minY, t.bbox.maxX, t.bbox.maxY);
      }
    }
    final bbox = minX == double.infinity
        ? null
        : Rect.fromLTRB(minX, minY, maxX, maxY);
    ref.read(selectionProvider.notifier).replace(SelectionState(
          strokeIds: newStrokes,
          shapeIds: newShapes,
          textIds: newTexts,
          bbox: bbox,
          pageId: widget.page.id,
        ));
    setState(() {
      _committedLasso = const [];
      _committedSelectRect = null;
    });
  }

  // ── Text action bar ────────────────────────────────────────────────
  Widget _buildTextActionBar() {
    final box = _findEditingTextBox();
    if (box == null) return const SizedBox.shrink();
    final left = box.bbox.minX;
    final top = (box.bbox.minY - 44).clamp(4.0, widget.page.spec.heightPt - 4);
    return Positioned(
      left: left,
      top: top,
      child: _TextEditingActionBar(
        onCopy: () => Clipboard.setData(ClipboardData(text: box.text)),
        onCut: () {
          Clipboard.setData(ClipboardData(text: box.text));
          widget.onTextChanged?.call(
              box.copyWith(deleted: true, rev: box.rev + 1));
          setState(() => _setEditingTextBoxId(null));
        },
        onDelete: () {
          FocusManager.instance.primaryFocus?.unfocus();
          widget.onTextChanged?.call(
              box.copyWith(deleted: true, rev: box.rev + 1));
          setState(() => _setEditingTextBoxId(null));
        },
      ),
    );
  }

  // ── Cursor helpers ─────────────────────────────────────────────────
  bool _shouldHideCursor(AppTool at) =>
      at == AppTool.pen ||
      at == AppTool.highlighter ||
      at == AppTool.tape ||
      at == AppTool.eraserArea ||
            at == AppTool.eraserStroke;

  @override
  Widget build(BuildContext context) {
    // Leaving the text tool exits any in-progress edit so the toolbar's
    // editingTextBoxIdProvider stops pointing at a stale box.
    ref.listen<AppTool>(
      toolProvider.select((s) => s.activeTool),
      (_, next) {
        if (next != AppTool.text && _editingTextBoxId != null) {
          FocusManager.instance.primaryFocus?.unfocus();
          _setEditingTextBoxId(null);
        }
      },
    );
    // Translucent when: stylus-only mode (fingers scroll) OR pinching (2-finger scroll/zoom).
    final hit = (widget.inputMode == InputMode.stylusOnly || widget.isPinching)
        ? HitTestBehavior.translucent
        : HitTestBehavior.opaque;
    final at = _appTool();

    final sortedLayers = [...widget.layers]
      ..sort((a, b) => a.z.compareTo(b.z));

    return MouseRegion(
      // Hide the system cursor and replace it with the brush-size circle.
      cursor: _shouldHideCursor(at)
          ? SystemMouseCursors.none
          : MouseCursor.defer,
      onHover: (e) {
        _cursorNotifier.value = e.localPosition;
        final held = _isStylusButtonHeld(e) || ref.read(spenButtonHeldProvider);
        if (_tempErasing != held && _builder == null) {
          setState(() => _tempErasing = held);
        }
      },
      onExit: (_) {
        _cursorNotifier.value = null;
        if (_tempErasing) setState(() => _tempErasing = false);
      },
      child: Listener(
      behavior: hit,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      child: Stack(
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter:
                  BackgroundPainter(background: widget.page.spec.background),
              size:
                  Size(widget.page.spec.widthPt, widget.page.spec.heightPt),
            ),
          ),
          if (widget.zoomNotifier != null)
            ValueListenableBuilder<double>(
              valueListenable: widget.zoomNotifier!,
              builder: (_, zoom, __) => BackgroundImageLayer(
                background: widget.page.spec.background,
                size: Size(widget.page.spec.widthPt, widget.page.spec.heightPt),
                zoom: zoom,
              ),
            )
          else
            BackgroundImageLayer(
              background: widget.page.spec.background,
              size: Size(widget.page.spec.widthPt, widget.page.spec.heightPt),
            ),
          // Active highlighter stroke — rendered before committed layer content
          // so it stays behind shapes/pen strokes, matching committed z-order.
          if (at != AppTool.eraserStroke &&
              at != AppTool.eraserArea &&
              widget.tool == ToolKind.highlighter)
            ValueListenableBuilder<List<StrokePoint>>(
              valueListenable: _liveNotifier,
              builder: (_, pts, __) => IgnorePointer(
                child: CustomPaint(
                  painter: ActiveStrokePainter(
                    points: pts,
                    tool: widget.tool,
                    colorArgb: widget.colorArgb,
                    widthPt: widget.widthPt,
                    opacity: widget.opacity,
                    lineStyle: _builder?.lineStyle ?? LineStyle.solid,
                    dashGap: _builder?.dashGap ?? 1.0,
                  ),
                  size: Size(
                      widget.page.spec.widthPt, widget.page.spec.heightPt),
                ),
              ),
            ),
          for (final layer in sortedLayers)
            if (layer.visible)
              ..._buildLayerSlices(layer),
          // Tape — top-most pass so tape is drawn above shapes/strokes/text.
          for (final layer in sortedLayers)
            if (layer.visible)
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: LayerPainter(
                      layer: layer,
                      strokes: widget.strokesByLayer[layer.id] ??
                          const <Stroke>[],
                      cache: _tapeCacheFor(layer.id),
                      revealedTapeIds: Set<String>.from(
                          ref.watch(notebookProvider
                              .select((s) => s.note.revealedTapeIds))),
                      tapeMode: LayerTapeMode.tapeOnly,
                      tapeRevealedOpacity:
                          ref.watch(toolProvider).tapeRevealedOpacity,
                    ),
                    size: Size(
                        widget.page.spec.widthPt, widget.page.spec.heightPt),
                  ),
                ),
              ),
          // Active stroke (in-progress drawing). Skip for eraser tools and
          // highlighter (handled in the pre-layer slot above).
          if (at != AppTool.eraserStroke &&
              at != AppTool.eraserArea &&
              widget.tool != ToolKind.highlighter)
            ValueListenableBuilder<List<StrokePoint>>(
              valueListenable: _liveNotifier,
              builder: (_, pts, __) => IgnorePointer(
                child: CustomPaint(
                  painter: ActiveStrokePainter(
                    points: pts,
                    tool: widget.tool,
                    colorArgb: widget.colorArgb,
                    widthPt: widget.widthPt,
                    opacity: widget.opacity,
                    lineStyle: _builder?.lineStyle ?? LineStyle.solid,
                    dashGap: _builder?.dashGap ?? 1.0,
                  ),
                  size: Size(
                      widget.page.spec.widthPt, widget.page.spec.heightPt),
                ),
              ),
            ),
          // Selection / lasso preview / shape preview.
          IgnorePointer(
            child: CustomPaint(
              painter: OverlayPainter(
                rect: _previewRect() ?? _committedSelectRect,
                shapePreview: _activeShapePreview(),
                // Live preview: open trail (don't close back to start point).
                // Committed selection: close the path so the selection
                // region reads as a region.
                lasso: _lassoPoints.length > 1
                    ? List<geom.Point2>.unmodifiable(_lassoPoints)
                    : _committedLasso.length > 1
                        ? _committedLasso
                        : null,
                lassoClosed: _lassoPoints.length <= 1 &&
                    _committedLasso.length > 1,
              ),
              size:
                  Size(widget.page.spec.widthPt, widget.page.spec.heightPt),
            ),
          ),
          // Selection bbox overlay.
          Consumer(builder: (context, wref, _) {
            final sel = wref.watch(selectionProvider);
            // Gate by pageId — selection belongs to one page only.
            if (sel.pageId != widget.page.id) {
              return const SizedBox.shrink();
            }
            final bbox = sel.bbox;
            if (sel.isEmpty || bbox == null) return const SizedBox.shrink();
            final zNotifier = widget.zoomNotifier;
            Widget overlay(double z) {
              final invZ = z == 0 ? 1.0 : 1.0 / z;
              final barLeft = (bbox.center.dx - 110 * invZ)
                  .clamp(4.0, widget.page.spec.widthPt - 220 * invZ);
              // Bar sits 70/z above the bbox so the rotate handle (22/z above)
              // remains visible and clickable between bar and bbox.
              final barTop = bbox.top < 70
                  ? (bbox.bottom + 30 * invZ)
                      .clamp(4.0, widget.page.spec.heightPt - 40 * invZ)
                  : (bbox.top - 70 * invZ)
                      .clamp(4.0, widget.page.spec.heightPt - 40 * invZ);
              return Stack(children: [
                IgnorePointer(
                  child: CustomPaint(
                    painter: SelectionOverlayPainter(
                      bbox: bbox,
                      zoom: z,
                      rotation: _rotateBaseRad + _rotateAccumRad,
                    ),
                    size: Size(
                        widget.page.spec.widthPt, widget.page.spec.heightPt),
                  ),
                ),
                // Floating action bar above the selection. Inverse-scaled so
                // it stays the same visual size regardless of canvas zoom.
                Positioned(
                  left: barLeft,
                  top: barTop,
                  child: Transform.scale(
                    scale: invZ,
                    alignment: Alignment.topLeft,
                    child: _SelectionActionBar(
                      onDelete: _deleteSelection,
                      onDuplicate: _duplicateSelection,
                      onBringForward: () => _reorderSelection(1),
                      onSendBackward: () => _reorderSelection(-1),
                      onBringToFront: () => _reorderSelection(2),
                      onSendToBack: () => _reorderSelection(0),
                    ),
                  ),
                ),
              ]);
            }
            if (zNotifier == null) return overlay(1.0);
            return ValueListenableBuilder<double>(
              valueListenable: zNotifier,
              builder: (_, z, __) => overlay(z),
            );
          }),
          // Text-editing action bar (delete / copy / cut).
          if (_editingTextBoxId != null &&
              at == AppTool.text)
            _buildTextActionBar(),
          // Unified cursor overlay — _CursorOverlay is its own
          // ConsumerStatefulWidget that directly watches toolProvider,
          // so it always has the latest width without relying on the
          // parent build() re-running.
          if (_shouldHideCursor(at))
            _CursorOverlay(
              positionNotifier: _cursorNotifier,
              appTool: at,
              isTempErasing: _tempErasing,
              pageWidth: widget.page.spec.widthPt,
              pageHeight: widget.page.spec.heightPt,
            ),
        ],
      ),
    ), // Listener
    ); // MouseRegion
  }

  ShapePreview? _activeShapePreview() {
    final tool = ref.read(toolProvider).activeTool;
    if (!_isShapeTool(tool)) return null;
    if (_dragStart == null || _dragCurrent == null) return null;
    final settings = ref.read(toolProvider);
    final kind = tool == AppTool.shapeRect
        ? ShapeKind.rectangle
        : tool == AppTool.shapeEllipse
            ? ShapeKind.ellipse
            : tool == AppTool.shapeDiamond
                ? ShapeKind.diamond
                : tool == AppTool.shapeArrow
                    ? ShapeKind.arrow
                    : tool == AppTool.shapeLine
                        ? ShapeKind.line
                        : ShapeKind.triangle;
    final ds2 = _dragStart!, dc2 = _dragCurrent!;
    return ShapePreview(
      kind: kind,
      strokeColor: Color(settings.penColor),
      strokeWidth: settings.penWidth,
      fillColor: settings.shapeFilled
          ? Color(settings.shapeFillColorArgb)
          : null,
      arrowFlipX: dc2.dx < ds2.dx,
      arrowFlipY: dc2.dy < ds2.dy,
    );
  }

  Rect? _previewRect() {
    final ds = _dragStart, dc = _dragCurrent;
    if (ds == null || dc == null) return null;
    final tool = ref.read(toolProvider).activeTool;
    if (tool != AppTool.rectSelect &&
        tool != AppTool.shapeRect &&
        tool != AppTool.shapeEllipse &&
        tool != AppTool.shapeTriangle &&
        tool != AppTool.shapeDiamond &&
        tool != AppTool.shapeArrow &&
        tool != AppTool.shapeLine) {
      return null;
    }
    final shiftLive = HardwareKeyboard.instance.isShiftPressed;
    if ((shiftLive || _autoRegularize) && _isShapeTool(tool)) {
      return _signedSquareFromDrag(ds, dc);
    }
    return Rect.fromPoints(ds, dc);
  }

  /// Build a square anchored at [start] whose extent matches the smaller
  /// of |dx|, |dy| but PRESERVES the drag direction — so dragging
  /// up-left produces a square going up-left (not stuck to start as
  /// top-left). Mirrors the reference editor's signed snapping.
  static Rect _signedSquareFromDrag(Offset start, Offset end) {
    var w = end.dx - start.dx;
    var h = end.dy - start.dy;
    final m = math.min(w.abs(), h.abs());
    w = w < 0 ? -m : m;
    h = h < 0 ? -m : m;
    return Rect.fromPoints(start, Offset(start.dx + w, start.dy + h));
  }
}

/// Floating action bar shown above the selection bbox.
class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.onDelete,
    required this.onDuplicate,
    required this.onBringForward,
    required this.onSendBackward,
    required this.onBringToFront,
    required this.onSendToBack,
  });
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final VoidCallback onBringForward;
  final VoidCallback onSendBackward;
  final VoidCallback onBringToFront;
  final VoidCallback onSendToBack;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionBtn(
              icon: Icons.content_copy_outlined,
              tooltip: '복제 (⌘D)',
              onTap: onDuplicate,
            ),
            _ActionBtn(
              icon: Icons.flip_to_front,
              tooltip: '앞으로 가져오기',
              onTap: onBringForward,
            ),
            _ActionBtn(
              icon: Icons.flip_to_back,
              tooltip: '뒤로 보내기',
              onTap: onSendBackward,
            ),
            _ActionBtn(
              icon: Icons.vertical_align_top,
              tooltip: '맨 앞으로',
              onTap: onBringToFront,
            ),
            _ActionBtn(
              icon: Icons.vertical_align_bottom,
              tooltip: '맨 뒤로',
              onTap: onSendToBack,
            ),
            _ActionBtn(
              icon: Icons.delete_outline,
              tooltip: '삭제 (Delete)',
              onTap: onDelete,
              danger: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Icon(
            icon,
            size: 18,
            color: danger ? const Color(0xFFEF4444) : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// Floating action bar shown above an editing text box.
class _TextEditingActionBar extends StatelessWidget {
  const _TextEditingActionBar({
    required this.onCopy,
    required this.onCut,
    required this.onDelete,
  });
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionBtn(
                icon: Icons.copy_outlined,
                tooltip: '복사',
                onTap: onCopy),
            _ActionBtn(
                icon: Icons.content_cut_rounded,
                tooltip: '잘라내기',
                onTap: onCut),
            _ActionBtn(
                icon: Icons.delete_outline,
                tooltip: '삭제',
                onTap: onDelete,
                danger: true),
          ],
        ),
      ),
    );
  }
}

/// Custom cursor — a circle whose size matches the brush or eraser radius.
///
/// Rendering modes:
///   • Eraser / no fill   : red outline ring (no fill) — shows eraser area.
///   • Brush (highlighter, tape) : filled disc in ink color + contrast edge —
///                                 previews exact stroke appearance.
///   • Pen (isPen = true) : crosshair + outline ring in ink color — shows the
///                          precise drawing point AND the stroke width.  A
///                          crosshair is used because pen draws fine lines,
///                          not broad filled areas.
class _BrushCursorPainter extends CustomPainter {
  _BrushCursorPainter({
    required this.center,
    required this.radius,
    this.isEraser = false,
    this.isPen = false,
    this.fillColor,
  });
  final Offset center;
  final double radius;
  final bool isEraser;
  /// True when the active tool is AppTool.pen — renders a crosshair cursor
  /// that shows the stroke tip and width without obscuring the canvas.
  final bool isPen;
  final Color? fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius.clamp(1.5, 600.0);

    // ── Eraser cursor: red outline ring ──────────────────────────────────
    if (isEraser || (!isPen && fillColor == null)) {
      canvas.drawCircle(
        center, r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = const Color(0xFFB91C1C),
      );
      return;
    }

    // ── Pen cursor: crosshair + outline ring in pen color ─────────────────
    if (isPen) {
      final color = (fillColor ?? const Color(0xFF333333)).withValues(alpha: 1.0);
      final luminance = color.computeLuminance();
      // Contrast halo so the cursor is visible on any background.
      final halo = luminance > 0.55
          ? const Color(0x88000000)
          : const Color(0xCCFFFFFF);

      // Outer ring shows stroke width.
      final ringR = r.clamp(3.0, 600.0);
      canvas.drawCircle(
        center, ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = halo,
      );
      canvas.drawCircle(
        center, ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = color,
      );

      // Crosshair — 6 px arms; shows the exact drawing tip.
      const armLen = 6.0;
      const gap = 1.5; // gap around center
      // draw halo first (thick), then color on top (thin)
      for (final paint in [
        Paint()
          ..strokeWidth = 2.5
          ..color = halo,
        Paint()
          ..strokeWidth = 1.0
          ..color = color,
      ]) {
        canvas.drawLine(Offset(center.dx - armLen, center.dy),
            Offset(center.dx - gap, center.dy), paint);
        canvas.drawLine(Offset(center.dx + gap, center.dy),
            Offset(center.dx + armLen, center.dy), paint);
        canvas.drawLine(Offset(center.dx, center.dy - armLen),
            Offset(center.dx, center.dy - gap), paint);
        canvas.drawLine(Offset(center.dx, center.dy + gap),
            Offset(center.dx, center.dy + armLen), paint);
      }
      return;
    }

    // ── Brush cursor (highlighter / tape): filled disc ────────────────────
    canvas.drawCircle(
      center, r,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor!,
    );
    // Contrast outline — pick dark on light fills, light on dark fills.
    final luminance = fillColor!.computeLuminance();
    final outline = luminance > 0.55
        ? const Color(0x99000000)
        : const Color(0xCCFFFFFF);
    canvas.drawCircle(
      center, r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = outline,
    );
  }

  @override
  bool shouldRepaint(covariant _BrushCursorPainter old) =>
      old.center != center ||
      old.radius != radius ||
      old.isEraser != isEraser ||
      old.isPen != isPen ||
      old.fillColor != fillColor;
}

/// Cursor overlay that independently watches [toolProvider] for width
/// changes and [positionNotifier] for position changes.
/// Being its own ConsumerStatefulWidget guarantees that a palette width
/// change triggers a rebuild of THIS widget directly — no closure-capture
/// or parent-build-re-run required.
class _CursorOverlay extends ConsumerStatefulWidget {
  const _CursorOverlay({
    required this.positionNotifier,
    required this.appTool,
    required this.isTempErasing,
    required this.pageWidth,
    required this.pageHeight,
  });

  final ValueNotifier<Offset?> positionNotifier;
  final AppTool appTool;
  final bool isTempErasing;
  final double pageWidth;
  final double pageHeight;

  @override
  ConsumerState<_CursorOverlay> createState() => _CursorOverlayState();
}

class _CursorOverlayState extends ConsumerState<_CursorOverlay> {
  @override
  void initState() {
    super.initState();
    widget.positionNotifier.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(_CursorOverlay old) {
    super.didUpdateWidget(old);
    if (old.positionNotifier != widget.positionNotifier) {
      old.positionNotifier.removeListener(_onPosition);
      widget.positionNotifier.addListener(_onPosition);
    }
  }

  @override
  void dispose() {
    widget.positionNotifier.removeListener(_onPosition);
    super.dispose();
  }

  void _onPosition() => setState(() {});

  @override
  Widget build(BuildContext context) {
    // ref.watch must run on every build so the toolProvider subscription is
    // re-registered even when the cursor is hidden — otherwise width/color
    // changes made while the pointer is off-canvas (or while a popup covers
    // it) don't propagate until the next pointer move.
    final ts = ref.watch(toolProvider);
    final double r;
    Color? fill;
    // pen tool now uses a filled disc just like highlighter — shows the actual
    // stroke tip (color + size) at the cursor position instead of a crosshair.
    const isPen = false;
    if (widget.isTempErasing) {
      r = effectiveEraserRadius(ts).clamp(1.0, 80.0);
    } else {
      switch (widget.appTool) {
        case AppTool.eraserArea:
        case AppTool.eraserStroke:
          r = effectiveEraserRadius(ts).clamp(1.0, 80.0);
        case AppTool.highlighter:
          r = (ts.highlighterWidth / 2).clamp(0.5, 80.0);
          fill = Color(ts.highlighterColor);
        case AppTool.tape:
          r = (ts.tapeWidth / 2).clamp(0.5, 80.0);
          fill = Color(ts.tapeColor);
        default: // pen — filled disc in pen color/size
          // Allow sub-pt radii (e.g. penWidth=0.7 → r=0.35) so the cursor
          // truly matches the stroke. Lower bound is just to avoid 0.
          r = (ts.penWidth / 2).clamp(0.1, 80.0);
          fill = Color(ts.penColor);
      }
    }

    final pos = widget.positionNotifier.value;
    if (pos == null) return const SizedBox.shrink();

    return IgnorePointer(
      child: CustomPaint(
        painter: _BrushCursorPainter(
          center: pos,
          radius: r,
          isEraser: widget.isTempErasing ||
              widget.appTool == AppTool.eraserArea ||
              widget.appTool == AppTool.eraserStroke,
          isPen: isPen,
          fillColor: fill,
        ),
        size: Size(widget.pageWidth, widget.pageHeight),
      ),
    );
  }
}

/// Renders a single [ImageObject] on the canvas by loading its file from
/// [AssetService] and displaying it at the object's bbox position/size.
class _CanvasImage extends StatefulWidget {
  const _CanvasImage({required this.image, required this.layerOpacity});
  final ImageObject image;
  final double layerOpacity;

  @override
  State<_CanvasImage> createState() => _CanvasImageState();
}

class _CanvasImageState extends State<_CanvasImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_CanvasImage old) {
    super.didUpdateWidget(old);
    if (old.image.assetId != widget.image.assetId) _load();
  }

  Future<void> _load() async {
    final f = await AssetService().fileFor(widget.image.assetId);
    if (mounted) setState(() => _file = f);
  }

  @override
  Widget build(BuildContext context) {
    final bbox = widget.image.bbox;
    final f = _file;
    return Positioned(
      left: bbox.minX,
      top: bbox.minY,
      width: bbox.maxX - bbox.minX,
      height: bbox.maxY - bbox.minY,
      child: Opacity(
        opacity: widget.layerOpacity.clamp(0.0, 1.0),
        child: f != null
            ? Image.file(f, fit: BoxFit.fill)
            : const SizedBox.shrink(),
      ),
    );
  }
}

