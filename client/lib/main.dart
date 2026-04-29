// Notee app entrypoint.
//
// Routing:
//   - currentNoteIdProvider == null → LibraryScreen (folders + notebooks)
//   - currentNoteIdProvider != null → EditorScreen (the canvas)
// The visual design follows the Claude Design handoff (paper-cream theme,
// Newsreader headings, mono labels). Theme tokens live in NoteeTheme.

import 'dart:async';
import 'dart:io' show Process;

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notee/domain/folder.dart';
import 'package:notee/domain/layer.dart';
import 'package:notee/domain/note.dart';
import 'package:notee/domain/page.dart';
import 'package:notee/domain/page_object.dart';
import 'package:notee/domain/page_spec.dart' show PdfBackground, ImageBackground;
import 'package:notee/features/auth/auth_state.dart';
import 'package:notee/features/auth/login_dialog.dart';
import 'package:notee/features/canvas/engine/input_gate.dart';
import 'package:notee/features/canvas/painters/layer_painter.dart' show LayerCache;
import 'package:notee/features/canvas/scroll/page_scroller.dart';
import 'package:notee/features/canvas/selection/selection_state.dart';
import 'package:notee/features/canvas/widgets/canvas_view.dart';
import 'package:notee/features/export/export_dialog.dart';
import 'package:notee/features/import/asset_service.dart';
import 'package:notee/features/import/image_importer.dart';
import 'package:notee/features/import/pdf_render_cache.dart';
import 'package:notee/features/library/library_screen.dart';
import 'package:notee/features/library/library_state.dart';
import 'package:notee/features/lock/note_lock_service.dart';
import 'package:notee/features/notebook/notebook_state.dart';
import 'package:notee/features/notebook/page_panel.dart';
import 'package:notee/features/notebook/page_strip.dart';
import 'package:notee/features/notebook/page_template_picker.dart';
import 'package:notee/features/sync/sync_actions.dart';
import 'package:notee/features/sync/sync_state.dart';
import 'package:notee/features/toolbar/toolbar.dart';
import 'package:notee/features/toolbar/toolbar_shell.dart'
    show ToolbarDock, toolbarDockProvider;
import 'package:notee/features/toolbar/tool_state.dart';
import 'package:notee/theme/notee_icons.dart';
import 'package:notee/theme/notee_popover.dart';
import 'package:notee/theme/notee_theme.dart';
import 'package:spen_remote/spen_remote.dart';
import 'package:notee/features/canvas/engine/spen_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore the user's PDF render thread count setting before any rendering
  // jobs start.
  try {
    final prefs = await SharedPreferences.getInstance();
    final n = prefs.getInt('pdf_render_threads');
    if (n != null) PdfRenderCache.instance.setMaxConcurrent(n);
  } catch (_) {}
  // Sweep any half-downloaded asset files left behind by a process kill
  // during the previous run. A leftover .partial — or a 0-byte final file
  // from a Dio error path that didn't finish — would otherwise be treated
  // as a complete asset on next sync and crash the PDF renderer.
  try {
    await AssetService().cleanupPartialDownloads();
  } catch (_) {}
  runApp(const ProviderScope(child: NoteeApp()));
}

final surfaceProvider = StateProvider<NoteeSurface>((ref) => NoteeSurface.paper);

class NoteeApp extends ConsumerWidget {
  const NoteeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surface = ref.watch(surfaceProvider);
    final theme = NoteeTheme.build(surface);
    return NoteeProvider(
      theme: theme,
      child: MaterialApp(
        title: 'Worstnote',
        debugShowCheckedModeBanner: false,
        theme: theme.material,
        home: const _Root(),
      ),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noteId = ref.watch(currentNoteIdProvider);
    return PopScope(
      canPop: noteId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Back button while in Editor → return to Library.
        // Lock release + final save happens inside EditorScreen.dispose.
        ref.read(currentNoteIdProvider.notifier).state = null;
      },
      child: noteId == null ? const LibraryScreen() : const EditorScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// EditorScreen — top bar + page toolbar + sidebar + canvas.
// ─────────────────────────────────────────────────────────────────────
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});
  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with SingleTickerProviderStateMixin {
  bool _showPages = false;
  int _activePageIndex = 0;
  // Scalar zoom — visual scale applied via Transform.scale (no matrix translation).
  // On zoom, _scrollController offset is adjusted to keep the focal point anchored.
  final ValueNotifier<double> _zoomNotifier = ValueNotifier(1.0);
  double get _zoom => _zoomNotifier.value;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 6.0;
  double _lastPinchScale = 1.0;
  // Active touch positions — tracked for Android pinch-to-zoom.
  final Map<int, Offset> _touchPositions = {};
  bool get _isPinching => _touchPositions.length >= 2;
  // Vertical scroll pending pattern (avoids stale reads on rapid events).
  double _pendingOffset = 0.0;
  bool _scrollJumpPending = false;
  // Horizontal scroll pending pattern — mirrors the vertical one.
  double _pendingHorizOffset = 0.0;
  bool _horizScrollJumpPending = false;
  // Viewport width in logical pixels (set each build from LayoutBuilder).
  double _viewportWidth = 0;

  // LayerCache maps — keyed by layerId, outlive CanvasView dispose so that
  // scrolling a page back into view skips re-recording the ui.Picture.
  final Map<String, LayerCache> _layerCaches = {};
  final Map<String, LayerCache> _tapeCaches = {};

  /// Owned by this state; passed to PageScroller (not disposed there).
  late final ScrollController _scrollController;

  /// Shared horizontal scroll controller — all page frames attach to this so
  /// they always scroll in unison. jumpTo() moves every visible page at once.
  late final ScrollController _horizScrollController;

  /// Key into PageScrollerState so we can call scrollToPage() imperatively.
  final _scrollerKey = GlobalKey<PageScrollerState>();

  /// Controls the page-strip slide-in/slide-out animation.
  late final AnimationController _sidebarAnim;

  StreamSubscription<dynamic>? _spenSub;
  StreamSubscription<dynamic>? _lockHandoffSub;
  String? _myNoteId;
  Timer? _autoSyncTimer;
  Timer? _commitTimer;
  bool _autoSyncing = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _horizScrollController = ScrollController()
      ..addListener(_syncHorizScroll);
    _sidebarAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 0.0, // starts hidden
    );
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    _initSpen();
    _initLock();
    _startAutoSync();
    _startCommitTimer();
    // Hide the Android system navigation bar while editing so the bottom
    // toolbar dock isn't covered by it. Swipe from the edge restores it.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: const [SystemUiOverlay.top],
    );
  }

  bool _horizSyncing = false;
  double _horizSyncTarget = 0.0;

  /// Keeps all page frames' horizontal scroll positions in sync.
  /// Fires whenever any attached SingleChildScrollView scrolls.
  void _syncHorizScroll() {
    if (_horizSyncing) return;
    if (!_horizScrollController.hasClients) return;
    final positions = _horizScrollController.positions.toList();
    if (positions.isEmpty) return;

    // Find the position that changed relative to the last known synced offset.
    // That's the page the user just scrolled — use it as the new target.
    double newTarget = _horizSyncTarget;
    for (final p in positions) {
      if ((p.pixels - _horizSyncTarget).abs() > 0.5) {
        newTarget = p.pixels;
        break;
      }
    }
    _horizSyncTarget = newTarget;

    // Nothing to sync if only one page is visible.
    if (positions.length < 2) return;

    _horizSyncing = true;
    for (final p in positions) {
      if ((p.pixels - newTarget).abs() > 0.5) {
        p.jumpTo(newTarget.clamp(0.0, p.maxScrollExtent));
      }
    }
    _horizSyncing = false;
  }

  void _initLock() {
    final noteId = ref.read(currentNoteIdProvider);
    if (noteId == null) return;
    _myNoteId = noteId;
    final lockService = ref.read(noteLockServiceProvider);
    // Acquire lock (handles dead-lock steal internally).
    lockService.acquire(noteId);
    // Listen for handoff requests from other instances.
    _lockHandoffSub = lockService.handoffRequests.listen((event) async {
      if (event.noteId != noteId) return;
      await _closeEditor(handoffSource: event.source);
    });
  }

  /// Unified exit: save → unlock → (send ack if handoff) → Library.
  /// Order matters: navigate-to-library must happen BEFORE the slow
  /// library refresh so that on a handoff the requester opens the editor
  /// only when the previous editor is already gone visually.
  Future<void> _closeEditor({String? handoffSource}) async {
    final noteId = ref.read(currentNoteIdProvider);
    if (noteId == null) return;
    final lockService = ref.read(noteLockServiceProvider);
    final libraryCtl = ref.read(libraryProvider.notifier);
    final notebook = ref.read(notebookProvider);
    final repo = ref.read(repositoryProvider);

    // If the note is completely empty (no user content) and has no PDF/image
    // background, silently delete it instead of saving.
    final hasPdfOrImageBackground = notebook.pages.any((p) =>
        p.spec.background is PdfBackground ||
        p.spec.background is ImageBackground);
    final hasContent = notebook.strokesByPage.values
            .any((l) => l.any((s) => !s.deleted)) ||
        notebook.shapesByPage.values.any((l) => l.any((s) => !s.deleted)) ||
        notebook.textsByPage.values.any((l) => l.any((t) => !t.deleted));

    if (!hasContent && !hasPdfOrImageBackground) {
      // Empty scratch note — discard without saving.
      await lockService.release(noteId);
      if (handoffSource != null) {
        await lockService.sendAck(toSession: handoffSource, noteId: noteId);
      }
      try { await repo.deleteNote(noteId); } catch (_) {}
      if (!mounted) return;
      ref.read(selectionProvider.notifier).clear();
      ref.read(currentNoteIdProvider.notifier).state = null;
      libraryCtl.refresh();
      return;
    }

    // 1. Force final save (synchronous flush).
    await ref.read(notebookProvider.notifier).flushDebounce();
    // 2. Release lock + ack the requester so they can take it.
    await lockService.release(noteId);
    if (handoffSource != null) {
      await lockService.sendAck(toSession: handoffSource, noteId: noteId);
    }
    if (!mounted) return;
    // 3. Navigate to library IMMEDIATELY.
    ref.read(selectionProvider.notifier).clear();
    ref.read(currentNoteIdProvider.notifier).state = null;
    // 4. Refresh library in the background (no longer awaited).
    libraryCtl.refresh();
    // 5. Push final state, then seal the editing session into a commit.
    //    Both run in the background so navigation isn't blocked.
    unawaited(() async {
      await ref.read(syncActionsProvider).pushNote(noteId);
      await ref.read(syncActionsProvider).commitNote(noteId);
    }());
  }

  Future<void> _initSpen() async {
    try {
      await SpenRemote.connect();
      _spenSub = SpenRemote.events.listen((event) {
        if (event.type == 'button') {
          final held = event.action == 0; // 0 = press, 1 = release
          ref.read(spenButtonHeldProvider.notifier).state = held;
        }
      });
    } catch (_) {
      // Not a Samsung device or S-Pen not available — ignore.
    }
  }

  void _startAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      if (_autoSyncing) return;
      final auth = ref.read(authProvider).value;
      if (auth == null || !auth.isLoggedIn) return;
      _autoSyncing = true;
      try {
        await ref.read(syncActionsProvider).syncNow();
      } catch (_) {} finally {
        _autoSyncing = false;
      }
    });
  }

  /// Every 3 minutes during editing, ask the server to seal pending
  /// revisions into a labeled commit. The actual commit is a server-side
  /// no-op if nothing was pushed since the last commit, so this is cheap
  /// to fire on a fixed cadence.
  void _startCommitTimer() {
    _commitTimer?.cancel();
    _commitTimer = Timer.periodic(const Duration(minutes: 3), (_) async {
      final noteId = ref.read(currentNoteIdProvider);
      if (noteId == null) return;
      final auth = ref.read(authProvider).value;
      if (auth == null || !auth.isLoggedIn) return;
      try {
        // Flush any pending local changes first so the commit captures them.
        await ref.read(notebookProvider.notifier).flushDebounce();
        await ref.read(syncActionsProvider).pushNote(noteId);
        await ref.read(syncActionsProvider).commitNote(noteId);
      } catch (_) {}
    });
  }

  @override
  void deactivate() {
    // Called before dispose while ref is still valid — release lock + flush save.
    if (_myNoteId != null) {
      ref.read(notebookProvider.notifier).flushDebounce();
      ref.read(noteLockServiceProvider).release(_myNoteId!);
      _myNoteId = null;
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    _commitTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    _scrollController.dispose();
    _horizScrollController.dispose();
    _sidebarAnim.dispose();
    _zoomNotifier.dispose();
    _spenSub?.cancel();
    _lockHandoffSub?.cancel();
    // Restore the system bars when leaving the editor.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  bool _hardwareKeyHandler(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;
    // Skip shortcut handling whenever the user is editing a text box.
    if (ref.read(editingTextBoxIdProvider) != null) return false;
    // Skip if any actual text-input widget has primary focus.
    final focused = FocusManager.instance.primaryFocus;
    final ctx = focused?.context;
    if (ctx != null) {
      final w = ctx.widget;
      if (w is EditableText) return false;
      if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) {
        return false;
      }
      // The EditableText sits as a descendant of the focused Focus widget
      // for TextField/TextFormField — check the immediate Focus child only.
      bool foundShallow = false;
      void shallow(Element el) {
        if (foundShallow) return;
        if (el.widget is EditableText) { foundShallow = true; return; }
        // Only one level deeper to avoid finding unrelated TextFields
        // elsewhere in the subtree of a high-up focused element.
      }
      ctx.visitChildElements((el) {
        shallow(el);
        if (!foundShallow) {
          el.visitChildElements(shallow);
        }
      });
      if (foundShallow) return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      final sel = ref.read(selectionProvider);
      if (sel.isNotEmpty) {
        final pageId =
            ref.read(notebookProvider).pages[_activePageIndex].id;
        ref
            .read(notebookProvider.notifier)
            .deleteObjects(pageId, sel.allIds);
        ref.read(selectionProvider.notifier).clear();
        return true;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      final sel = ref.read(selectionProvider);
      if (sel.isNotEmpty) {
        ref.read(selectionProvider.notifier).clear();
        return true;
      }
    }

    if (HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ &&
          !HardwareKeyboard.instance.isControlPressed) {
        final notifier = ref.read(notebookProvider.notifier);
        if (HardwareKeyboard.instance.isShiftPressed) {
          notifier.redo();
        } else {
          notifier.undo();
        }
        return true;
      }
      // Cmd/Ctrl + 1..6 → switch pen palette color slot (use physicalKey
      // so the mapping is layout-independent and works with modifiers held).
      const _colorPhysKeys = [
        PhysicalKeyboardKey.digit1,
        PhysicalKeyboardKey.digit2,
        PhysicalKeyboardKey.digit3,
        PhysicalKeyboardKey.digit4,
        PhysicalKeyboardKey.digit5,
        PhysicalKeyboardKey.digit6,
      ];
      final colorIdx = _colorPhysKeys.indexOf(event.physicalKey);
      if (colorIdx >= 0) {
        final ts = ref.read(toolProvider);
        final tn = ref.read(toolProvider.notifier);
        final colors = ts.penPaletteColors;
        if (colorIdx < colors.length) {
          tn.setPenColor(colors[colorIdx]);
        }
        return true;
      }
      return false;
    }

    if (HardwareKeyboard.instance.isAltPressed) {
      // Opt/Alt + 1..5 → switch pen palette width slot
      const _widthPhysKeys = [
        PhysicalKeyboardKey.digit1,
        PhysicalKeyboardKey.digit2,
        PhysicalKeyboardKey.digit3,
        PhysicalKeyboardKey.digit4,
        PhysicalKeyboardKey.digit5,
      ];
      final widthIdx = _widthPhysKeys.indexOf(event.physicalKey);
      if (widthIdx >= 0) {
        final ts = ref.read(toolProvider);
        final tn = ref.read(toolProvider.notifier);
        final widths = ts.penPaletteWidths;
        if (widthIdx < widths.length) {
          tn.setPenWidth(widths[widthIdx]);
        }
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyL) {
      final tn = ref.read(toolProvider.notifier);
      final ts = ref.read(toolProvider);
      // Cycle: anything → lasso → rectSelect → lasso → ...
      if (ts.activeTool == AppTool.lasso) {
        tn.setTool(AppTool.rectSelect);
      } else if (ts.activeTool == AppTool.rectSelect) {
        tn.setTool(AppTool.lasso);
      } else {
        tn.setTool(AppTool.lasso);
      }
      return true;
    }

    final tool = _shortcuts[event.logicalKey];
    if (tool != null) {
      ref.read(toolProvider.notifier).setTool(tool);
      return true;
    }
    return false;
  }

  void _togglePages() {
    setState(() => _showPages = !_showPages);
    if (_showPages) {
      _sidebarAnim.forward();
    } else {
      _sidebarAnim.reverse();
    }
  }

  /// Apply [factor] (relative scale) around [focal] (viewport coords).
  /// Both the vertical scroll controller and the shared horizontal scroll
  /// controller are adjusted so the content point under the cursor stays
  /// visually anchored after the zoom change.
  void _zoomAround(Offset focal, double factor) {
    final oldZoom = _zoom;
    final newZoom = (oldZoom * factor).clamp(_minZoom, _maxZoom);
    if ((newZoom - oldZoom).abs() < 1e-4) return;

    // ── Vertical anchor ──────────────────────────────────────────────────
    if (!_scrollJumpPending && _scrollController.hasClients) {
      _pendingOffset = _scrollController.offset;
    }
    _pendingOffset += focal.dy * (1.0 / oldZoom - 1.0 / newZoom);

    // ── Horizontal anchor ─────────────────────────────────────────────────
    if (_horizScrollController.hasClients && _viewportWidth > 0) {
      final state = ref.read(notebookProvider);
      final pageW = _activePageIndex < state.pages.length
          ? state.pages[_activePageIndex].spec.widthPt
          : 0.0;

      if (!_horizScrollJumpPending) {
        _pendingHorizOffset = _horizScrollController.positions.first.pixels;
      }

      final virtualW = _viewportWidth / oldZoom;
      double newH;
      if (pageW > virtualW) {
        newH = _pendingHorizOffset + focal.dx * (1.0 / oldZoom - 1.0 / newZoom);
      } else if (pageW > _viewportWidth / newZoom) {
        final centerMargin = (virtualW - pageW) / 2;
        final contentX = focal.dx / oldZoom - centerMargin;
        newH = contentX - focal.dx / newZoom;
      } else {
        newH = 0.0;
      }

      final maxH = (pageW - _viewportWidth / newZoom).clamp(0.0, double.infinity);
      _pendingHorizOffset = newH.clamp(0.0, maxH);

      // Apply immediately (same frame as zoom) to avoid 1-frame drift.
      for (final pos in _horizScrollController.positions) {
        pos.correctPixels(_pendingHorizOffset);
        pos.notifyListeners();
      }

      // Fallback: clamp to new maxScrollExtent after layout at new zoom.
      if (!_horizScrollJumpPending) {
        _horizScrollJumpPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _horizScrollJumpPending = false;
          if (!mounted || !_horizScrollController.hasClients) return;
          for (final pos in _horizScrollController.positions) {
            final clamped = _pendingHorizOffset.clamp(0.0, pos.maxScrollExtent);
            if ((pos.pixels - clamped).abs() > 0.5) pos.jumpTo(clamped);
          }
        });
      }
    }

    // Update zoom without setState — ValueListenableBuilder handles repaint.
    _zoomNotifier.value = newZoom;

    // Apply vertical scroll correction in the same frame as the zoom change.
    // correctPixels() sets the offset without waiting for layout; the
    // addPostFrameCallback below clamps it to maxScrollExtent once layout
    // has run at the new zoom level.
    if (_scrollController.hasClients) {
      _scrollController.position.correctPixels(_pendingOffset);
      _scrollController.position.notifyListeners();
    }

    if (!_scrollJumpPending) {
      _scrollJumpPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollJumpPending = false;
        if (!mounted || !_scrollController.hasClients) return;
        final maxExtent = _scrollController.position.maxScrollExtent;
        final clamped = _pendingOffset.clamp(0.0, maxExtent);
        if ((_scrollController.offset - clamped).abs() > 0.5) {
          _scrollController.jumpTo(clamped);
        }
      });
    }
  }

  Future<void> _onPullToAddTemplate() async {
    final state = ref.read(notebookProvider);
    if (state.pages.isEmpty) return;
    // Pull-to-add appends a copy of the last page's spec — no picker.
    ref.read(notebookProvider.notifier).addPage(spec: state.pages.last.spec);
  }

  // Map letter keys → tool. Final (not const) because LogicalKeyboardKey
  // has custom equality.
  static final _shortcuts = <LogicalKeyboardKey, AppTool>{
    LogicalKeyboardKey.keyP: AppTool.pen,
    LogicalKeyboardKey.keyH: AppTool.highlighter,
    LogicalKeyboardKey.keyE: AppTool.eraserStroke,
    LogicalKeyboardKey.keyL: AppTool.lasso,
    LogicalKeyboardKey.keyT: AppTool.text,
    LogicalKeyboardKey.keyR: AppTool.shapeRect,
    LogicalKeyboardKey.keyO: AppTool.shapeEllipse,
    LogicalKeyboardKey.keyA: AppTool.tape,
  };


  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final state = ref.watch(notebookProvider);
    final ctl = ref.read(notebookProvider.notifier);
    final tool = ref.watch(toolProvider);
    final note = state.note;
    final stylusOnly = tool.inputDrawMode == InputDrawMode.stylusOnly;

    final dock = ref.watch(toolbarDockProvider);
    final toolbarIsVertical = dock == ToolbarDock.left || dock == ToolbarDock.right;
    final toolbar = PageToolbarBar(axis: toolbarIsVertical ? Axis.vertical : Axis.horizontal);
    // The page strip + canvas area (shared across dock positions).
    final canvasArea = Expanded(
      child: Row(children: [
        if (dock == ToolbarDock.left) toolbar,
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: _showPages
              ? PageStrip(
                  pages: state.pages,
                  activePageIndex: _activePageIndex,
                  onSelect: (i) =>
                      _scrollerKey.currentState?.scrollToPage(i),
                )
              : const SizedBox.shrink(),
        ),
              Expanded(child: Stack(children: [
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent &&
                        HardwareKeyboard.instance.isMetaPressed) {
                      _zoomAround(
                        e.localPosition,
                        (1.0 - e.scrollDelta.dy * 0.0015),
                      );
                    }
                  },
                  onPointerPanZoomStart: (_) {
                    _lastPinchScale = 1.0;
                    if (_scrollController.hasClients) {
                      _pendingOffset = _scrollController.offset;
                    }
                  },
                  onPointerPanZoomUpdate: (e) {
                    if (e.scale == 1.0) return;
                    final factor = e.scale / _lastPinchScale;
                    _lastPinchScale = e.scale;
                    _zoomAround(e.localPosition, factor);
                  },
                  onPointerPanZoomEnd: (_) {
                    _lastPinchScale = 1.0;
                  },
                  // Android touch: track positions for pinch-to-zoom.
                  onPointerDown: (e) {
                    if (e.kind != PointerDeviceKind.touch) return;
                    _touchPositions[e.pointer] = e.localPosition;
                    // Rebuild so isPinching flag propagates to CanvasView.
                    if (_touchPositions.length == 2) setState(() {});
                  },
                  onPointerMove: (e) {
                    if (e.kind != PointerDeviceKind.touch) return;
                    if (!_touchPositions.containsKey(e.pointer)) return;
                    if (_touchPositions.length == 2) {
                      final otherId = _touchPositions.keys
                          .firstWhere((id) => id != e.pointer);
                      final oldDist = (_touchPositions[e.pointer]! -
                              _touchPositions[otherId]!)
                          .distance;
                      _touchPositions[e.pointer] = e.localPosition;
                      final newDist = (_touchPositions[e.pointer]! -
                              _touchPositions[otherId]!)
                          .distance;
                      if (oldDist > 0 && (newDist / oldDist - 1.0).abs() > 0.005) {
                        _zoomAround(e.localPosition, newDist / oldDist);
                      }
                    } else {
                      _touchPositions[e.pointer] = e.localPosition;
                    }
                  },
                  onPointerUp: (e) {
                    if (e.kind != PointerDeviceKind.touch) return;
                    _touchPositions.remove(e.pointer);
                    setState(() {});
                  },
                  onPointerCancel: (e) {
                    if (e.kind != PointerDeviceKind.touch) return;
                    _touchPositions.remove(e.pointer);
                    setState(() {});
                  },
                  child: Stack(children: [
                    // Scrollbar lives outside the Transform so it is not
                    // scaled with the content.
                    Scrollbar(
                      controller: _scrollController,
                      child: LayoutBuilder(builder: (ctx, constraints) {
                        _viewportWidth = constraints.maxWidth;
                        // PageScroller is the child — it is NOT rebuilt when
                        // _zoomNotifier fires, only when setState() fires.
                        final scroller = PageScroller(
                          key: _scrollerKey,
                          note: note,
                          pages: state.pages,
                          scrollController: _scrollController,
                          horizScrollController: _horizScrollController,
                          zoom: 1.0,
                          showScrollbar: false,
                          stylusOnly: stylusOnly,
                          pageBuilder: (context, page) {
                            final layers = state.layersByPage[page.id] ??
                                const <Layer>[];
                            return RepaintBoundary(
                              child: _CanvasFor(
                                pageId: page.id,
                                page: page,
                                layers: layers,
                                tool: tool,
                                isPinching: _isPinching,
                                layerCaches: _layerCaches,
                                tapeCaches: _tapeCaches,
                                zoomNotifier: _zoomNotifier,
                              ),
                            );
                          },
                          onPageChanged: (i) =>
                              setState(() => _activePageIndex = i),
                          onPullToAddTemplate: _onPullToAddTemplate,
                        );
                        return ValueListenableBuilder<double>(
                          valueListenable: _zoomNotifier,
                          // RepaintBoundary: page content is cached as a GPU
                          // layer — zoom transform composites it without repaint.
                          child: RepaintBoundary(child: scroller),
                          builder: (_, zoom, scrollerChild) => ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              minHeight: 0,
                              maxWidth: constraints.maxWidth / zoom,
                              maxHeight: constraints.maxHeight / zoom,
                              child: Transform.scale(
                                scale: zoom,
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  width: constraints.maxWidth / zoom,
                                  height: constraints.maxHeight / zoom,
                                  child: scrollerChild,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    // Cloud sync status — top-left corner of canvas.
                    const Positioned(
                      left: 10,
                      top: 10,
                      child: _CanvasCloudStatus(),
                    ),
                    // Zoom-reset button — shown when not at 100%.
                    ValueListenableBuilder<double>(
                      valueListenable: _zoomNotifier,
                      builder: (_, zoom, __) => (zoom - 1.0).abs() > 0.05
                          ? Positioned(
                              right: 12,
                              top: 12,
                              child: GestureDetector(
                                onTap: () => _zoomNotifier.value = 1.0,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${(zoom * 100).round()}%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'JetBrainsMono',
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ]),
                ),
              ),
            ])),
            if (dock == ToolbarDock.right) toolbar,
            ]),
    );
    final hasStatusBar = MediaQuery.viewPaddingOf(context).top > 0;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        top: hasStatusBar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EditorTopBar(
              stylusOnly: stylusOnly,
              showPages: _showPages,
              activePageIndex: _activePageIndex,
              totalPages: state.pages.length,
              onTogglePages: _togglePages,
              onBack: () => _closeEditor(),
              onTitleChanged: ctl.setTitle,
              onToggleStylusOnly: () => ref.read(toolProvider.notifier).setInputDrawMode(
                stylusOnly ? InputDrawMode.any : InputDrawMode.stylusOnly,
              ),
              onScrollToPage: (i) => _scrollerKey.currentState?.scrollToPage(i),
            ),
            if (dock == ToolbarDock.top) toolbar,
            canvasArea,
            if (dock == ToolbarDock.bottom) toolbar,
          ],
        ),
      ),
      drawer: Drawer(
        child: _PagePanelHost(
          onScrollToPage: (i) => _scrollerKey.currentState?.scrollToPage(i),
        ),
      ),
    );
  }
}

// ── Top bar (back · pages-toggle · breadcrumb · title · page counter ·
//            saved · undo · redo · stylus toggle · settings · search · share) ─
class _EditorTopBar extends ConsumerStatefulWidget {
  const _EditorTopBar({
    required this.stylusOnly,
    required this.showPages,
    required this.activePageIndex,
    required this.totalPages,
    required this.onTogglePages,
    required this.onBack,
    required this.onTitleChanged,
    required this.onToggleStylusOnly,
    this.onScrollToPage,
  });
  final bool stylusOnly;
  final bool showPages;
  final int activePageIndex;
  final int totalPages;
  final VoidCallback onTogglePages;
  final VoidCallback onBack;
  final void Function(String) onTitleChanged;
  final VoidCallback onToggleStylusOnly;
  final void Function(int pageIndex)? onScrollToPage;

  @override
  ConsumerState<_EditorTopBar> createState() => _EditorTopBarState();
}

class _EditorTopBarState extends ConsumerState<_EditorTopBar> {
  bool _exporting = false;
  bool _syncBusy = false;

  Future<void> _syncNow() async {
    setState(() => _syncBusy = true);
    try {
      final r = await ref.read(syncActionsProvider).syncNow();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sync OK · pushed ${r.pushed} · pulled ${r.pulled}'),
      ));
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && e.response?.statusCode == 401) {
        await ref.read(authProvider.notifier).logout();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('세션이 만료되었습니다. 다시 로그인해주세요.'),
        ));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sync failed: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final state = ref.read(notebookProvider);
      final path = await ExportDialog.show(context, state,
          suggestedName: state.note.title);
      if (path != null && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        late ScaffoldFeatureController<SnackBar, SnackBarClosedReason> ctrl;
        ctrl = messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Row(
              children: [
                Expanded(child: Text('저장됨: $path')),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => ctrl.close(),
                ),
              ],
            ),
            action: SnackBarAction(
              label: '열기',
              onPressed: () => _openFile(path),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share() => _export();

  void _openFile(String path) {
    Process.run('open', [path]);
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final state = ref.watch(notebookProvider);
    final ctl = ref.read(notebookProvider.notifier);
    final note = state.note;
    final lib = ref.watch(libraryProvider);

    String? folderName;
    final fid = note.folderId;
    if (fid != null) {
      final folders = lib.value?.folders ?? const <Folder>[];
      for (final f in folders) {
        if (f.id == fid) {
          folderName = f.name;
          break;
        }
      }
    }

    // height: 44 lets the parent Column(crossAxisAlignment: stretch) enforce
    // full width, which is what we want on all screen sizes.
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: t.toolbar,
        border: Border(bottom: BorderSide(color: t.tbBorder, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        // ── Left: back / toggle / breadcrumb / title ──────────────────
        IconButton(
          tooltip: 'Library',
          icon: NoteeIconWidget(NoteeIcon.left, size: 16, color: t.ink),
          onPressed: widget.onBack,
        ),
        IconButton(
          tooltip: 'Page list',
          icon: NoteeIconWidget(
            NoteeIcon.rows,
            size: 15,
            color: widget.showPages ? t.accent : t.ink,
          ),
          onPressed: widget.onTogglePages,
        ),
        Container(width: 1, height: 16, color: t.rule),
        const SizedBox(width: 8),
        if (folderName != null) ...[
          NoteeIconWidget(NoteeIcon.folder, size: 13, color: t.inkDim),
          const SizedBox(width: 6),
          Text(folderName,
              style: TextStyle(fontSize: 12, color: t.inkDim)),
          const SizedBox(width: 6),
          NoteeIconWidget(NoteeIcon.chev, size: 9, color: t.inkFaint),
          const SizedBox(width: 6),
        ],
        // Title expands to fill remaining space, pushing right icons flush right.
        Expanded(
          child: _EditableTitle(
            title: note.title,
            onChanged: widget.onTitleChanged,
          ),
        ),
        const SizedBox(width: 8),
        const SizedBox(width: 8),
        // ── Right: saved indicator / undo / redo / tools ─────────────
        Text('saved · just now',
            style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                color: t.inkFaint)),
        const SizedBox(width: 4),
        _NoteSettingsBtn(
          stylusOnly: widget.stylusOnly,
          onToggleStylusOnly: widget.onToggleStylusOnly,
          onExport: _share,
          exporting: _exporting,
        ),
        _EditorCloudButton(onSyncNow: _syncBusy ? null : _syncNow),
      ]),
    );
  }
}

class _NoteSettingsBtn extends ConsumerStatefulWidget {
  const _NoteSettingsBtn({
    required this.stylusOnly,
    required this.onToggleStylusOnly,
    required this.onExport,
    required this.exporting,
  });
  final bool stylusOnly;
  final VoidCallback onToggleStylusOnly;
  final VoidCallback onExport;
  final bool exporting;
  @override
  ConsumerState<_NoteSettingsBtn> createState() => _NoteSettingsBtnState();
}

class _NoteSettingsBtnState extends ConsumerState<_NoteSettingsBtn> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return KeyedSubtree(
      key: _key,
      child: IconButton(
        tooltip: 'Settings',
        icon: NoteeIconWidget(NoteeIcon.gear, size: 16, color: t.ink),
        onPressed: _open,
      ),
    );
  }

  Future<void> _open() async {
    dismissActivePassthroughPopover();
    final note = ref.read(notebookProvider).note;
    final ctl = ref.read(notebookProvider.notifier);
    final toolCtl = ref.read(toolProvider.notifier);
    final tapeOpacity = ref.read(toolProvider).tapeRevealedOpacity;
    final dock = ref.read(toolbarDockProvider);
    await showNoteePopover<void>(
      context,
      anchorKey: _key,
      maxWidth: 260,
      builder: (_) => _SettingsContent(
        scrollAxis: note.scrollAxis,
        onScrollAxis: ctl.setScrollAxis,
        stylusOnly: widget.stylusOnly,
        onToggleStylusOnly: widget.onToggleStylusOnly,
        onShowAllTapes: () => ref.read(notebookProvider.notifier).showAllTapes(),
        onHideAllTapes: () => ref.read(notebookProvider.notifier).hideAllTapes(),
        tapeRevealedOpacity: tapeOpacity,
        onTapeRevealedOpacity: toolCtl.setTapeRevealedOpacity,
        toolbarDock: dock,
        onToolbarDock: (d) => ref.read(toolbarDockProvider.notifier).state = d,
        onExport: widget.onExport,
        exporting: widget.exporting,
      ),
    );
  }
}

class _SettingsContent extends StatefulWidget {
  const _SettingsContent({
    required this.scrollAxis,
    required this.onScrollAxis,
    required this.stylusOnly,
    required this.onToggleStylusOnly,
    required this.onShowAllTapes,
    required this.onHideAllTapes,
    required this.tapeRevealedOpacity,
    required this.onTapeRevealedOpacity,
    required this.toolbarDock,
    required this.onToolbarDock,
    required this.onExport,
    required this.exporting,
  });
  final ScrollAxis scrollAxis;
  final void Function(ScrollAxis) onScrollAxis;
  final bool stylusOnly;
  final VoidCallback onToggleStylusOnly;
  final VoidCallback onShowAllTapes;
  final VoidCallback onHideAllTapes;
  final double tapeRevealedOpacity;
  final void Function(double) onTapeRevealedOpacity;
  final ToolbarDock toolbarDock;
  final void Function(ToolbarDock) onToolbarDock;
  final VoidCallback onExport;
  final bool exporting;
  @override
  State<_SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<_SettingsContent> {
  late ScrollAxis _axis;
  late bool _stylusOnly;
  late double _tapeOpacity;
  late ToolbarDock _dock;
  @override
  void initState() {
    super.initState();
    _axis = widget.scrollAxis;
    _stylusOnly = widget.stylusOnly;
    _tapeOpacity = widget.tapeRevealedOpacity;
    _dock = widget.toolbarDock;
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Input mode
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('INPUT MODE', style: noteeSectionEyebrow(t)),
        ),
        _SettingsSegment(
          options: const [
            ('Pen only', true),
            ('Touch enabled', false),
          ],
          value: _stylusOnly,
          onChanged: (v) {
            if (v == _stylusOnly) return;
            setState(() => _stylusOnly = v);
            widget.onToggleStylusOnly();
          },
        ),
        const SizedBox(height: 16),
        // Scroll axis
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('SCROLL AXIS', style: noteeSectionEyebrow(t)),
        ),
        _SettingsSegment(
          options: const [
            ('Vertical', ScrollAxis.vertical),
            ('Horizontal', ScrollAxis.horizontal),
          ],
          value: _axis,
          onChanged: (v) {
            setState(() => _axis = v);
            widget.onScrollAxis(v);
          },
        ),
        const SizedBox(height: 16),
        // Tape — action buttons + opacity slider
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('TAPE', style: noteeSectionEyebrow(t)),
        ),
        Row(children: [
          Expanded(
            child: _SettingsActionBtn(
              label: 'Show all',
              onTap: widget.onShowAllTapes,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _SettingsActionBtn(
              label: 'Hide all',
              onTap: widget.onHideAllTapes,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text('투명도 (반투명 상태)', style: TextStyle(fontSize: 11, color: t.inkDim)),
        ),
        Row(children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: _tapeOpacity,
                min: 0.05,
                max: 0.95,
                divisions: 18,
                activeColor: t.accent,
                inactiveColor: t.tbBorder,
                onChanged: (v) {
                  setState(() => _tapeOpacity = v);
                  widget.onTapeRevealedOpacity(v);
                },
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '${(_tapeOpacity * 100).round()}%',
              style: TextStyle(fontSize: 12, color: t.inkDim),
              textAlign: TextAlign.end,
            ),
          ),
        ]),
        const SizedBox(height: 16),
        // Toolbar position
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('TOOLBAR 위치', style: noteeSectionEyebrow(t)),
        ),
        _SettingsSegment<ToolbarDock>(
          options: const [
            ('상단', ToolbarDock.top),
            ('하단', ToolbarDock.bottom),
            ('왼쪽', ToolbarDock.left),
            ('오른쪽', ToolbarDock.right),
          ],
          value: _dock,
          onChanged: (v) {
            setState(() => _dock = v);
            widget.onToolbarDock(v);
          },
        ),
        const SizedBox(height: 16),
        // Export
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text('EXPORT', style: noteeSectionEyebrow(t)),
        ),
        MouseRegion(
          cursor: widget.exporting
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.exporting ? null : widget.onExport,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: t.accentSoft,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.tbBorder, width: 0.5),
              ),
              alignment: Alignment.center,
              child: widget.exporting
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: t.accent),
                    )
                  : Text(
                      '내보내기',
                      style: TextStyle(
                        fontFamily: 'Inter Tight',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: t.accent,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SettingsActionBtn extends StatelessWidget {
  const _SettingsActionBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.tbBorder, width: 0.5),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter Tight',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: t.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSegment<T> extends StatelessWidget {
  const _SettingsSegment({
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final List<(String, T)> options;
  final T value;
  final void Function(T) onChanged;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.tbBorder, width: 0.5),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(children: [
        for (final opt in options)
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(opt.$2),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        opt.$2 == value ? t.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    opt.$1,
                    style: TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 12.5,
                      fontWeight:
                          opt.$2 == value ? FontWeight.w600 : FontWeight.w500,
                      color: opt.$2 == value ? t.accent : t.ink,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _EditableTitle extends StatefulWidget {
  const _EditableTitle({required this.title, required this.onChanged});
  final String title;
  final void Function(String) onChanged;
  @override
  State<_EditableTitle> createState() => _EditableTitleState();
}

class _EditableTitleState extends State<_EditableTitle> {
  late final TextEditingController _ctl;
  bool _editing = false;
  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.title);
  }

  @override
  void didUpdateWidget(covariant _EditableTitle old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title && !_editing) _ctl.text = widget.title;
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    if (_editing) {
      return SizedBox(
        width: 240,
        child: TextField(
          controller: _ctl,
          autofocus: true,
          style: TextStyle(
            fontFamily: 'Inter Tight',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
          ),
          onSubmitted: (v) {
            setState(() => _editing = false);
            widget.onChanged(v.isEmpty ? widget.title : v);
          },
        ),
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _editing = true),
      child: Text(
        widget.title,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Inter Tight',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: t.ink,
        ),
      ),
    );
  }
}

class _FloatingSideActions extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FloatingSideActions> createState() =>
      _FloatingSideActionsState();
}

class _FloatingSideActionsState extends ConsumerState<_FloatingSideActions> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Material(
      color: t.toolbar,
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _EditorCloudButton(onSyncNow: _busy ? null : _syncNow),
        ]),
      ),
    );
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(syncActionsProvider).syncNow();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sync OK · pushed ${r.pushed} · pulled ${r.pulled}'),
      ));
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && e.response?.statusCode == 401) {
        await ref.read(authProvider.notifier).logout();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('세션이 만료되었습니다. 다시 로그인해주세요.'),
        ));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sync failed: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ─── Canvas cloud status chip (top-left of note canvas) ──────────────────

class _CanvasCloudStatus extends ConsumerWidget {
  const _CanvasCloudStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = ref.watch(cloudSyncProvider);

    if (cloud.status == CloudSyncStatus.notLoggedIn) return const SizedBox.shrink();

    final icon = switch (cloud.status) {
      CloudSyncStatus.notLoggedIn => Icons.cloud_outlined,
      CloudSyncStatus.idle        => Icons.cloud,
      CloudSyncStatus.checking    => Icons.sync,
      CloudSyncStatus.syncing     => Icons.sync,
      CloudSyncStatus.ok          => Icons.cloud_done,
      CloudSyncStatus.error       => Icons.cloud_off,
    };

    final String label;
    if (cloud.status == CloudSyncStatus.syncing &&
        cloud.syncTotal != null && cloud.syncTotal! > 0) {
      label = '동기화중… (${cloud.syncCurrent ?? 0}/${cloud.syncTotal})';
    } else {
      label = switch (cloud.status) {
        CloudSyncStatus.notLoggedIn => '',
        CloudSyncStatus.idle        => '연결됨',
        CloudSyncStatus.checking    => '확인 중',
        CloudSyncStatus.syncing     => '동기화중…',
        CloudSyncStatus.ok          => '연결됨',
        CloudSyncStatus.error       => '오프라인',
      };
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: Colors.white70),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontFamily: 'Inter Tight',
              fontSize: 11,
            ),
          ),
        ],
      ]),
    );
  }
}

// ─── Editor Cloud Button ───────────────────────────────────────────────────

class _EditorCloudButton extends ConsumerStatefulWidget {
  const _EditorCloudButton({required this.onSyncNow});
  final VoidCallback? onSyncNow;

  @override
  ConsumerState<_EditorCloudButton> createState() => _EditorCloudButtonState();
}

class _EditorCloudButtonState extends ConsumerState<_EditorCloudButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final cloud = ref.watch(cloudSyncProvider);

    if (cloud.status == CloudSyncStatus.checking ||
        cloud.status == CloudSyncStatus.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_spin.isAnimating) _spin.stop();
    }

    final (icon, color) = switch (cloud.status) {
      CloudSyncStatus.notLoggedIn => (Icons.cloud_outlined, t.inkFaint),
      CloudSyncStatus.idle        => (Icons.cloud,          t.inkDim),
      CloudSyncStatus.checking    => (Icons.sync,           t.accent),
      CloudSyncStatus.syncing     => (Icons.sync,           t.accent),
      CloudSyncStatus.ok          => (Icons.cloud_done,     t.accent),
      CloudSyncStatus.error       => (Icons.cloud_off,      t.inkFaint),
    };

    Widget iconWidget = Icon(icon, size: 18, color: color);
    if (cloud.status == CloudSyncStatus.checking ||
        cloud.status == CloudSyncStatus.syncing) {
      iconWidget = RotationTransition(turns: _spin, child: iconWidget);
    }

    final tooltip = switch (cloud.status) {
      CloudSyncStatus.notLoggedIn => '로그인',
      CloudSyncStatus.idle        => '연결됨',
      CloudSyncStatus.checking    => '확인 중…',
      CloudSyncStatus.syncing     => '싱크 중…',
      CloudSyncStatus.ok          => '연결됨',
      CloudSyncStatus.error       => '오프라인',
    };

    return IconButton(
      tooltip: tooltip,
      icon: iconWidget,
      onPressed: _openModal,
    );
  }

  Future<void> _openModal() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EditorCloudDialog(onSyncNow: widget.onSyncNow),
    );
  }
}

class _EditorCloudDialog extends ConsumerWidget {
  const _EditorCloudDialog({required this.onSyncNow});
  final VoidCallback? onSyncNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final cloud = ref.watch(cloudSyncProvider);
    final loggedIn = ref.watch(authProvider).value?.isLoggedIn ?? false;

    final (icon, iconColor) = switch (cloud.status) {
      CloudSyncStatus.notLoggedIn => (Icons.cloud_outlined, t.inkFaint),
      CloudSyncStatus.idle        => (Icons.cloud,          t.accent),
      CloudSyncStatus.checking    => (Icons.sync,           t.accent),
      CloudSyncStatus.syncing     => (Icons.sync,           t.accent),
      CloudSyncStatus.ok          => (Icons.cloud_done,     const Color(0xFF4CAF50)),
      CloudSyncStatus.error       => (Icons.cloud_off,      t.inkFaint),
    };

    final String statusLabel;
    if (cloud.status == CloudSyncStatus.syncing &&
        cloud.syncTotal != null && cloud.syncTotal! > 0) {
      statusLabel = '동기화중… (${cloud.syncCurrent ?? 0}/${cloud.syncTotal})';
    } else {
      statusLabel = switch (cloud.status) {
        CloudSyncStatus.notLoggedIn => '로그인 필요',
        CloudSyncStatus.idle        => '연결됨',
        CloudSyncStatus.checking    => '확인 중…',
        CloudSyncStatus.syncing     => '동기화중…',
        CloudSyncStatus.ok          => '연결됨',
        CloudSyncStatus.error       => '오프라인',
      };
    }

    final labelStyle = TextStyle(
      fontFamily: 'Inter Tight',
      fontSize: 13,
      color: t.inkDim,
    );

    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 8),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontFamily: 'Newsreader',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
              ]),
              if (cloud.serverUrl != null) ...[
                const SizedBox(height: 6),
                Text(
                  cloud.serverUrl!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: t.inkFaint,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (cloud.errorMessage != null) ...[
                const SizedBox(height: 6),
                Text(
                  cloud.errorMessage!,
                  style: const TextStyle(
                    fontFamily: 'Inter Tight',
                    fontSize: 11,
                    color: Color(0xFFDC2626),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 16),
              Divider(height: 1, thickness: 1, color: t.tbBorder),
              const SizedBox(height: 12),
              if (!loggedIn)
                TextButton.icon(
                  icon: Icon(Icons.login, size: 16, color: t.accent),
                  label: Text('로그인', style: TextStyle(color: t.accent, fontFamily: 'Inter Tight', fontSize: 13)),
                  onPressed: () {
                    Navigator.pop(context);
                    showDialog<void>(
                      context: context,
                      builder: (_) => const LoginDialog(),
                    );
                  },
                )
              else ...[
                if (onSyncNow != null)
                  TextButton.icon(
                    icon: Icon(Icons.sync, size: 16, color: t.accent),
                    label: Text('지금 동기화', style: labelStyle.copyWith(color: t.accent)),
                    onPressed: () {
                      Navigator.pop(context);
                      onSyncNow!();
                    },
                  ),
                TextButton.icon(
                  icon: Icon(Icons.refresh, size: 16, color: t.inkDim),
                  label: Text('연결 확인', style: labelStyle),
                  onPressed: () {
                    Navigator.pop(context);
                    ref.read(cloudSyncProvider.notifier).checkNow();
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.logout, size: 16, color: Color(0xFFDC2626)),
                  label: Text('로그아웃', style: labelStyle.copyWith(color: const Color(0xFFDC2626))),
                  onPressed: () {
                    Navigator.pop(context);
                    ref.read(authProvider.notifier).logout();
                  },
                ),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('닫기', style: TextStyle(fontFamily: 'Inter Tight', fontSize: 13, color: t.inkDim)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CanvasFor extends ConsumerWidget {
  const _CanvasFor({
    required this.pageId,
    required this.page,
    required this.layers,
    required this.tool,
    this.isPinching = false,
    this.layerCaches,
    this.tapeCaches,
    this.zoomNotifier,
  });
  final String pageId;
  final NotePage page;
  final List<Layer> layers;
  final ToolState tool;
  final bool isPinching;
  final Map<String, LayerCache>? layerCaches;
  final Map<String, LayerCache>? tapeCaches;
  final ValueNotifier<double>? zoomNotifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notebookProvider);
    final ctl = ref.read(notebookProvider.notifier);
    final note = state.note;

    final strokesByLayer =
        _groupBy<Stroke>(state.strokesByPage[pageId] ?? const <Stroke>[]);
    final shapesByLayer = _groupBy<ShapeObject>(
        state.shapesByPage[pageId] ?? const <ShapeObject>[]);
    final textsByLayer = _groupBy<TextBoxObject>(
        state.textsByPage[pageId] ?? const <TextBoxObject>[]);

    final activeLayerId = state.activeLayerByPage[pageId] ?? '';
    final inputMode = tool.inputDrawMode == InputDrawMode.stylusOnly
        ? InputMode.stylusOnly
        : InputMode.any;

    final at = tool.activeTool;
    final kind = toolKindFor(at);
    final int color;
    final double width;
    final double opacity;
    switch (at) {
      case AppTool.highlighter:
        color = tool.highlighterColor;
        width = tool.highlighterWidth;
        opacity = 1.0; // alpha lives in the color itself now
      case AppTool.eraserStroke:
        color = 0xFFFFFFFF;
        width = 12.0;
        opacity = 1.0;
      case AppTool.tape:
        color = tool.tapeColor;
        width = tool.tapeWidth;
        opacity = 1.0;
      default:
        color = tool.penColor;
        width = tool.penWidth;
        opacity = 1.0;
    }

    return CanvasView(
      page: page,
      layers: layers,
      strokesByLayer: strokesByLayer,
      shapesByLayer: shapesByLayer,
      textsByLayer: textsByLayer,
      activeLayerId: activeLayerId,
      tool: kind,
      colorArgb: color,
      widthPt: width,
      opacity: opacity,
      inputMode: inputMode,
      isPinching: isPinching,
      layerCaches: layerCaches,
      tapeCaches: tapeCaches,
      zoomNotifier: zoomNotifier,
      onStrokeCommitted: ctl.addStroke,
      onShapeCommitted: ctl.addShape,
      onTextCommitted: ctl.addText,
      onTextChanged: ctl.updateText,
      onEraseStrokes: (ids) => ctl.removeStrokes(pageId, ids),
      onEraseObjects: (ids) => ctl.deleteObjects(pageId, ids),
    );
  }
}

Map<String, List<T>> _groupBy<T>(List<T> all) {
  final map = <String, List<T>>{};
  for (final o in all) {
    String id;
    if (o is Stroke) {
      id = o.layerId;
    } else if (o is ShapeObject) {
      id = o.layerId;
    } else if (o is TextBoxObject) {
      id = o.layerId;
    } else {
      continue;
    }
    map.putIfAbsent(id, () => <T>[]).add(o);
  }
  return map;
}

class _PagePanelHost extends ConsumerWidget {
  const _PagePanelHost({this.onScrollToPage});
  final void Function(int)? onScrollToPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notebookProvider);
    final ctl = ref.read(notebookProvider.notifier);
    final activeId =
        state.pages.isNotEmpty ? state.pages.first.id : null;
    return PagePanel(
      pages: state.pages,
      activePageId: activeId,
      onSelect: (pageId) {
        final idx = state.pages.indexWhere((p) => p.id == pageId);
        if (idx >= 0) onScrollToPage?.call(idx);
        Navigator.of(context).pop(); // close the drawer
      },
      onAdd: () => ctl.addPage(),
      onDelete: (id) => ctl.removePage(id),
      onChangeSpec: ctl.setPageSpec,
      onImportImage: () async {
        final imp = await ImageImporter().pickAndImport();
        if (imp == null) return;
        ctl.addPage(spec: imp.spec);
      },
    );
  }
}


