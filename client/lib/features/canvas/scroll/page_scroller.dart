// PageScroller renders the pages of a [Note] in either vertical or
// horizontal flow. Switch is a single field on the note: changing it
// rebuilds the scroll view but does not touch any page data.
//
// MVP scope (P2):
//   - Vertical scroll: top→bottom, gap between pages.
//   - Horizontal scroll: regular Scrollable (trackpad / wheel / arrow keys)
//     on desktop. PageView snap variant for mobile lands later.
//   - Page sizes vary per page (A4, Letter, Custom, PDF imports). Layout
//     uses each page's [PageSpec] for sizing.
//   - Only ±1 pages from the visible viewport render their committed
//     layers; off-screen pages render thumbnails to bound memory (P3+).
//
// The PageView itself is a thin wrapper around Flutter primitives; the heavy
// lifting (drawing engine, painters) is hosted per-page.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../domain/note.dart';
import '../../../domain/page.dart';
import '../../../domain/page_spec.dart';
import '../../../theme/notee_icons.dart';
import '../../../theme/notee_theme.dart';
import '../../import/asset_service.dart';
import '../../import/pdf_render_cache.dart';
import '../../library/thumbnail_service.dart';

/// Builds the canvas widget for a single page.
/// Implementations live in the canvas/widgets folder.
typedef PageCanvasBuilder = Widget Function(
  BuildContext context,
  NotePage page,
);

class PageScroller extends StatefulWidget {
  const PageScroller({
    super.key,
    required this.note,
    required this.pages,
    required this.pageBuilder,
    required this.scrollController,
    this.horizScrollController,
    this.gap = 16.0,
    this.zoom = 1.0,
    this.showScrollbar = true,
    this.onPageChanged,
    this.onPullToAddTemplate,
    this.stylusOnly = false,
  });

  final Note note;
  final List<NotePage> pages;
  final PageCanvasBuilder pageBuilder;
  final ScrollController scrollController;
  /// Shared horizontal scroll controller used by every page frame so all
  /// pages scroll horizontally in unison.
  final ScrollController? horizScrollController;
  final double gap;
  final double zoom;
  final bool showScrollbar;
  final void Function(int)? onPageChanged;
  final Future<void> Function()? onPullToAddTemplate;
  final bool stylusOnly;

  @override
  State<PageScroller> createState() => PageScrollerState();
}

class PageScrollerState extends State<PageScroller>
    with SingleTickerProviderStateMixin {
  int _currentPage = 0;
  double _pullOffset = 0.0;
  bool _pullTriggered = false;
  int? _pullPointerId; // pointer driving the pull gesture
  double? _pullStartY;  // screen Y where overscroll began
  late final AnimationController _snapBack;
  late double _snapBackFrom;

  @override
  void initState() {
    super.initState();
    _snapBack = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
        if (!_pullTriggered) {
          setState(() => _pullOffset = _snapBackFrom * (1 - _snapBack.value));
        }
      });
    widget.scrollController.addListener(_scrollListener);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePdfCache());
  }

  @override
  void didUpdateWidget(PageScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_scrollListener);
      widget.scrollController.addListener(_scrollListener);
    }
  }

  @override
  void dispose() {
    _snapBack.dispose();
    widget.scrollController.removeListener(_scrollListener);
    super.dispose();
  }

  bool _atScrollBottom() {
    if (!widget.scrollController.hasClients) return false;
    final pos = widget.scrollController.position;
    return pos.pixels >= pos.maxScrollExtent - 4;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pullTriggered) return;
    // Only the vertical scroll axis matters.
    if (widget.note.scrollAxis != ScrollAxis.vertical) return;
    // Accept only touch (finger) — stylus draws.
    if (e.kind != PointerDeviceKind.touch) return;
    // Lock to the first pointer that started the pull.
    if (_pullPointerId != null && _pullPointerId != e.pointer) return;

    // Finger swiping UP (dy < 0) at the bottom = trying to overscroll down.
    if (e.delta.dy < 0 && _atScrollBottom()) {
      _snapBack.stop();
      if (_pullPointerId == null) {
        // Only begin a pull gesture when the finger is moving slowly —
        // fast flings that happen to reach the bottom must not auto-trigger.
        const maxStartSpeed = 5.0; // px per event ≈ slow deliberate drag
        if (-e.delta.dy <= maxStartSpeed) {
          _pullPointerId = e.pointer;
          _pullStartY = e.position.dy;
          _snapBack.stop();
          setState(() => _pullOffset = 0); // always start from 0
        }
        return;
      }
      if (_pullPointerId == e.pointer && _pullStartY != null) {
        final travel = (_pullStartY! - e.position.dy).clamp(0.0, 450.0);
        setState(() => _pullOffset = travel);
      }
    } else if (_pullOffset > 0 && _pullPointerId == e.pointer) {
      if (_pullStartY != null) {
        final travel = (_pullStartY! - e.position.dy).clamp(0.0, 450.0);
        setState(() => _pullOffset = travel);
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pullPointerId && _pullOffset == 0) return;
    _pullPointerId = null;
    _pullStartY = null;
    if (_pullTriggered) return;

    if (_pullOffset >= 300) {
      _pullTriggered = true;
      setState(() => _pullOffset = 300.0);
      widget.onPullToAddTemplate?.call().then((_) {
        if (mounted) {
          _snapBackFrom = _pullOffset;
          _pullPointerId = null;
          _pullStartY = null;
          setState(() => _pullTriggered = false);
          _snapBack.forward(from: 0);
        }
      });
    } else if (_pullOffset > 0) {
      _snapBackFrom = _pullOffset;
      _snapBack.forward(from: 0);
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (_pullOffset > 0 && !_pullTriggered) {
      _pullPointerId = null;
      _pullStartY = null;
      _snapBackFrom = _pullOffset;
      _snapBack.forward(from: 0);
    }
  }

  void _scrollListener() {
    if (!widget.scrollController.hasClients) return;
    final offset = widget.scrollController.offset;
    double pos = widget.gap;
    for (var i = 0; i < widget.pages.length; i++) {
      final pageH = widget.pages[i].spec.heightPt * widget.zoom;
      if (offset < pos + pageH / 2 || i == widget.pages.length - 1) {
        if (_currentPage != i) {
          setState(() => _currentPage = i);
          widget.onPageChanged?.call(i);
        }
        break;
      }
      pos += pageH + widget.gap;
    }
  }

  /// Ensures 25% thumbnail cache files exist for all PDF pages and pre-warms
  /// the pdfrx document cache for off-screen pages.
  Future<void> _ensurePdfCache() async {
    final seen = <String>{};
    final toRender =
        <({File file, String assetId, int pageNo, Size pageSize})>[];
    final toLoad = <({String assetId, String filePath})>[];

    for (final page in widget.pages) {
      final bg = page.spec.background;
      if (bg is! PdfBackground) continue;

      // Queue 25% thumbnail renders for pages not yet cached.
      final key = '${bg.assetId}_${bg.pageNo}';
      if (!seen.contains(key)) {
        seen.add(key);
        final file = await AssetService().fileFor(bg.assetId);
        if (file != null) {
          toRender.add((
            file: file,
            assetId: bg.assetId,
            pageNo: bg.pageNo,
            pageSize: Size(page.spec.widthPt, page.spec.heightPt),
          ));
          // Also collect unique asset files for pdfrx document pre-warm.
          if (!toLoad.any((e) => e.assetId == bg.assetId)) {
            toLoad.add((assetId: bg.assetId, filePath: file.path));
          }
        }
      }
    }

    PdfRenderCache.instance.ensureThumbnails(toRender);

    // Keep pre-warming the pdfrx document cache as before.
    for (final entry in toLoad) {
      if (!mounted) return;
      final ref = PdfDocumentRefFile(entry.filePath, autoDispose: false);
      ref.resolveListenable().load();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Animate the scroll position to the given page index.
  void scrollToPage(int index) {
    double offset = widget.gap;
    for (var i = 0; i < index; i++) {
      offset += widget.pages[i].spec.heightPt * widget.zoom + widget.gap;
    }
    widget.scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final axis = widget.note.scrollAxis == ScrollAxis.vertical
        ? Axis.vertical
        : Axis.horizontal;

    // Decide which pointer kinds the scroller may steal as a "drag to scroll"
    // gesture. The general rule: any pointer kind that the canvas accepts as
    // a drawing input MUST NOT be in this set, otherwise the same drag would
    // both draw and scroll.
    //
    // Mouse-wheel and two-finger trackpad pan fire separate event types
    // (PointerScrollEvent / PointerPanZoom*Event) and bypass dragDevices —
    // those continue to work regardless of what's in this set.
    //
    //   - any        : stylus + mouse + (touch on touchscreens) all draw, so
    //                  ONLY two-finger trackpad pan is allowed to scroll.
    //   - stylusOnly : stylus draws; everything else (finger, mouse drag,
    //                  trackpad) is free to scroll.
    final scrollDevices =
        widget.stylusOnly
            ? <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
              }
            : <PointerDeviceKind>{
                PointerDeviceKind.trackpad,
              };

    // Total item count: pages + 1 sentinel pull-to-add row (vertical only).
    final showPullToAdd = axis == Axis.vertical;
    final itemCount =
        widget.pages.length + (showPullToAdd ? 1 : 0);

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: scrollDevices,
        scrollbars: widget.showScrollbar,
      ),
      child: Listener(
        // Listener receives raw PointerEvents before gesture arena resolution,
        // so it fires even when the drawing canvas consumes the gesture.
        behavior: HitTestBehavior.translucent,
        onPointerMove: showPullToAdd ? _onPointerMove : null,
        onPointerUp: showPullToAdd ? _onPointerUp : null,
        onPointerCancel: showPullToAdd ? _onPointerCancel : null,
        child: _MaybeScrollbar(
          show: widget.showScrollbar,
          controller: widget.scrollController,
          child: ListView.separated(
            controller: widget.scrollController,
            scrollDirection: axis,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            itemCount: itemCount,
            separatorBuilder: (_, __) => SizedBox(
              width: axis == Axis.horizontal ? widget.gap : 0,
              height: axis == Axis.vertical ? widget.gap : 0,
            ),
            padding: axis == Axis.vertical
                ? EdgeInsets.symmetric(vertical: widget.gap)
                : EdgeInsets.symmetric(horizontal: widget.gap),
            itemBuilder: (context, i) {
              // Last item is the pull-to-add sentinel row.
              if (showPullToAdd && i == widget.pages.length) {
                return _PullToAddRow(
                  progress: (_pullOffset / 300.0).clamp(0.0, 1.0),
                  triggered: _pullTriggered,
                );
              }
              final page = widget.pages[i];
              return _PageFrame(
                page: page,
                zoom: widget.zoom,
                horizController: widget.horizScrollController,
                child: widget.pageBuilder(context, page),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Pull-to-add indicator ────────────────────────────────────────────────
class _PullToAddRow extends StatelessWidget {
  const _PullToAddRow({
    required this.progress,
    required this.triggered,
  });

  /// 0..1 — how far the user has pulled.
  final double progress;
  final bool triggered;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final rowH = (120.0 * progress).clamp(0.0, 120.0);
    if (rowH < 2) return const SizedBox.shrink();

    final label = triggered ? '페이지 추가됨' : '당겨서 페이지 추가하기';

    return SizedBox(
      height: rowH,
      child: Opacity(
        opacity: progress.clamp(0.0, 1.0),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: CustomPaint(
                  painter: _CircleProgressPainter(
                    progress: triggered ? 1.0 : progress,
                    ringColor: t.inkDim,
                    fillColor: t.inkDim.withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: triggered
                        ? Icon(Icons.check_rounded,
                            size: 22, color: t.inkDim)
                        : Icon(Icons.arrow_downward_rounded,
                            size: 22, color: t.inkDim),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: t.inkDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleProgressPainter extends CustomPainter {
  const _CircleProgressPainter({
    required this.progress,
    required this.ringColor,
    required this.fillColor,
  });

  final double progress;
  final Color ringColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 3;
    const startAngle = -1.5707963267948966; // -π/2 (12 o'clock)

    // Background track.
    final trackPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // Filled background disc.
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = fillColor,
    );

    // Sweeping arc.
    if (progress > 0) {
      final arcPaint = Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        6.283185307179586 * progress, // 2π × progress
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CircleProgressPainter old) =>
      old.progress != progress || old.ringColor != ringColor;
}

// ── Page frame ────────────────────────────────────────────────────────────
// Wraps each page's canvas. Loads a pre-rendered low-res thumbnail from
// ThumbnailService and shows it as an underlay so content is visible
// immediately while fast-scrolling before PDF/image backgrounds finish loading.
class _PageFrame extends StatefulWidget {
  const _PageFrame({
    super.key,
    required this.page,
    required this.child,
    this.zoom = 1.0,
    this.horizController,
  });

  final NotePage page;
  final Widget child;
  final double zoom;
  final ScrollController? horizController;

  @override
  State<_PageFrame> createState() => _PageFrameState();
}

class _PageFrameState extends State<_PageFrame> {
  Uint8List? _thumb;
  // False until the thumbnail cache lookup finishes. Canvas stays hidden
  // (but still initializes) so the thumbnail is visible as a placeholder.
  bool _canvasReady = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PageFrame old) {
    super.didUpdateWidget(old);
    if (old.page.id != widget.page.id) {
      setState(() { _thumb = null; _canvasReady = false; });
      _load();
    }
  }

  Future<void> _load() async {
    final bytes =
        await ThumbnailService.instance.getCachedPage(widget.page.id);
    if (mounted) setState(() { _thumb = bytes; _canvasReady = true; });
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.page.spec.widthPt;
    final h = widget.page.spec.heightPt;
    final pageW = w * widget.zoom;
    final pageH = h * widget.zoom;

    final thumb = _thumb;
    final pageBox = Material(
      elevation: 2,
      color: Colors.white,
      child: SizedBox(
        width: pageW,
        height: pageH,
        child: Stack(children: [
          // Thumbnail shown until canvas is ready (and as permanent underlay
          // for PDF backgrounds that take time to load).
          if (thumb != null)
            Positioned.fill(
              child: Image.memory(thumb, fit: BoxFit.fill),
            ),
          // Canvas starts initializing immediately but stays invisible until
          // the thumbnail cache check is done, so it doesn't flash on top.
          Positioned.fill(
            child: Offstage(
              offstage: !_canvasReady,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: ClipRect(child: widget.child),
                ),
              ),
            ),
          ),
        ]),
      ),
    );

    return LayoutBuilder(builder: (ctx, constraints) {
      return SingleChildScrollView(
        controller: widget.horizController,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Center(child: pageBox),
        ),
      );
    });
  }
}

class _MaybeScrollbar extends StatelessWidget {
  const _MaybeScrollbar({
    required this.show,
    required this.controller,
    required this.child,
  });
  final bool show;
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!show) return child;
    return Scrollbar(controller: controller, child: child);
  }
}
