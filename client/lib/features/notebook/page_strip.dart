// PageStrip — left sidebar of small page thumbnails.
//
// Interaction:
//   • Tap            → onSelect(index)
//   • Header "+"     → template picker → insert at end
//   • Right-click / long-press → context menu (앞에 추가 / 뒤에 추가 / 삭제)
//
// Thumbnails:
//   • Aspect ratio matches the page's PageSpec (A4, Letter, Square, …)
//   • BackgroundPainter draws the page pattern (grid / ruled / dot / blank)
//   • All committed strokes for the page are drawn at thumbnail scale so
//     content updates live as the user draws.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/page.dart';
import '../../domain/page_spec.dart';
import '../../domain/page_object.dart'; // Stroke
import '../canvas/painters/background_painter.dart';
import '../import/asset_service.dart';
import '../library/thumbnail_service.dart';
import '../notebook/notebook_state.dart';
import '../notebook/page_template_picker.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_popover.dart';
import '../../theme/notee_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PageStrip
// ─────────────────────────────────────────────────────────────────────────────
class PageStrip extends ConsumerWidget {
  const PageStrip({
    super.key,
    required this.pages,
    required this.activePageIndex,
    required this.onSelect,
  });

  final List<NotePage> pages;
  final int activePageIndex;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    return Container(
      width: 156,
      decoration: BoxDecoration(
        color: t.toolbar,
        border: Border(right: BorderSide(color: t.tbBorder, width: 0.5)),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(children: [
            Expanded(
              child: Text(
                'PAGES · ${pages.length}',
                style: noteeSectionEyebrow(t),
              ),
            ),
            GestureDetector(
              onTap: () => _addPage(context, ref),
              child: NoteeIconWidget(NoteeIcon.plus,
                  size: 11, color: t.inkFaint),
            ),
          ]),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
            buildDefaultDragHandles: false,
            itemCount: pages.length,
            onReorder: (oldIndex, newIndex) {
              final adjusted =
                  newIndex > oldIndex ? newIndex - 1 : newIndex;
              ref
                  .read(notebookProvider.notifier)
                  .reorderPage(oldIndex, adjusted);
            },
            itemBuilder: (context, i) => _PageThumbnailItem(
              key: ValueKey(pages[i].id),
              page: pages[i],
              index: i,
              selected: i == activePageIndex,
              onTap: () => onSelect(i),
              onContextMenu: (pos) =>
                  _showContextMenu(context, ref, i, pos),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Header "+" — template picker then append ───────────────────────────────
  Future<void> _addPage(BuildContext context, WidgetRef ref) async {
    final currentSpec = pages.isNotEmpty ? pages.last.spec : null;
    final spec =
        await showPageTemplatePicker(context, currentSpec: currentSpec);
    if (spec == null || !context.mounted) return;
    ref.read(notebookProvider.notifier).addPage(spec: spec);
  }

  // ── Context menu ───────────────────────────────────────────────────────────
  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    int pageIndex,
    Offset globalPos,
  ) async {
    final action = await showNoteeMenuAt<_PageAction>(
      context,
      position: globalPos,
      items: [
        const NoteeMenuItem(
          label: '앞에 페이지 추가',
          value: _PageAction.addBefore,
          icon: NoteeIconWidget(NoteeIcon.plus, size: 14),
        ),
        const NoteeMenuItem(
          label: '뒤에 페이지 추가',
          value: _PageAction.addAfter,
          icon: NoteeIconWidget(NoteeIcon.plus, size: 14),
        ),
        const NoteeMenuItem.separator(),
        NoteeMenuItem(
          label: '페이지 삭제',
          value: _PageAction.delete,
          danger: true,
          icon: const NoteeIconWidget(NoteeIcon.trash, size: 14),
          subtitle: pages.length <= 1 ? '마지막 페이지는 삭제할 수 없어요' : null,
        ),
      ],
    );

    if (action == null || !context.mounted) return;
    final ctl = ref.read(notebookProvider.notifier);
    final page = pages[pageIndex];

    if (action == _PageAction.delete) {
      if (pages.length > 1) ctl.removePage(page.id);
      return;
    }

    final currentSpec =
        pages.isNotEmpty ? pages[pageIndex].spec : null;
    final spec =
        await showPageTemplatePicker(context, currentSpec: currentSpec);
    if (spec == null || !context.mounted) return;

    if (action == _PageAction.addBefore) {
      ctl.addPage(spec: spec, at: pageIndex);
    } else {
      ctl.addPage(spec: spec, at: pageIndex + 1);
    }
  }
}

enum _PageAction { addBefore, addAfter, delete }

// ─────────────────────────────────────────────────────────────────────────────
// _PageThumbnailItem — watches the notebook state for live updates,
// and uses a pre-generated cached thumbnail as the static base layer.
// ─────────────────────────────────────────────────────────────────────────────
class _PageThumbnailItem extends ConsumerStatefulWidget {
  const _PageThumbnailItem({
    super.key,
    required this.page,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onContextMenu,
  });

  final NotePage page;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset globalPos) onContextMenu;

  @override
  ConsumerState<_PageThumbnailItem> createState() => _PageThumbnailItemState();
}

class _PageThumbnailItemState extends ConsumerState<_PageThumbnailItem> {
  Uint8List? _cachedThumb;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(_PageThumbnailItem old) {
    super.didUpdateWidget(old);
    if (old.page.id != widget.page.id) {
      _cachedThumb = null;
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final bytes =
        await ThumbnailService.instance.getCachedPage(widget.page.id);
    if (mounted && bytes != null) setState(() => _cachedThumb = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final page = widget.page;

    // Only re-build when strokes for THIS page change.
    final strokes = ref.watch(
      notebookProvider
          .select((s) => s.strokesByPage[page.id] ?? const <Stroke>[]),
    );
    final shapes = ref.watch(
      notebookProvider.select(
          (s) => s.shapesByPage[page.id] ?? const <ShapeObject>[]),
    );
    final texts = ref.watch(
      notebookProvider.select(
          (s) => s.textsByPage[page.id] ?? const <TextBoxObject>[]),
    );

    // Ensure a thumbnail exists for this page — schedule generation if not.
    ThumbnailService.instance.schedulePage(
      pageId: page.id,
      spec: page.spec,
      strokes: strokes,
      shapes: shapes,
      texts: texts,
    );

    const thumbW = 118.0;
    final ratio = page.spec.widthPt / page.spec.heightPt;
    final thumbH = thumbW / ratio;

    final hasPdfOrImage = page.spec.background is ImageBackground ||
        page.spec.background is PdfBackground;
    final hasCachedThumb = _cachedThumb != null && !hasPdfOrImage;
    final hasLiveContent =
        strokes.isNotEmpty || shapes.isNotEmpty || texts.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: widget.onTap,
            onSecondaryTapUp: (d) => widget.onContextMenu(d.globalPosition),
            onLongPressStart: (d) {
              HapticFeedback.mediumImpact();
              widget.onContextMenu(d.globalPosition);
            },
            child: Container(
              width: thumbW,
              height: thumbH,
              decoration: BoxDecoration(
                color: t.page,
                borderRadius: BorderRadius.circular(3),
                boxShadow: widget.selected
                    ? [
                        BoxShadow(color: t.accent, spreadRadius: 1.5),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [
                        BoxShadow(color: t.pageEdge, spreadRadius: 0.5),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(children: [
                // ── Base layer ──────────────────────────────────────────
                // Prefer cached PNG (instant); fall back to async/live painters.
                if (hasCachedThumb)
                  Positioned.fill(
                    child: Image.memory(_cachedThumb!, fit: BoxFit.fill),
                  )
                else if (page.spec.background
                    case ImageBackground(:final assetId))
                  Positioned.fill(child: _AsyncThumbnailImage(assetId: assetId))
                else if (page.spec.background
                    case PdfBackground(:final assetId, :final pageNo))
                  Positioned.fill(
                    child: _AsyncThumbnailPdf(assetId: assetId, pageNo: pageNo),
                  )
                else
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ThumbnailPainter(
                        spec: page.spec,
                        strokes: const [],
                        shapes: const [],
                        texts: const [],
                      ),
                    ),
                  ),
                // ── Live overlay ─────────────────────────────────────────
                // When using cached PNG as base, still show live strokes on
                // top so edits appear instantly before the cache is refreshed.
                if (hasCachedThumb && hasLiveContent)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ThumbnailPainter(
                        spec: page.spec,
                        strokes: strokes,
                        shapes: shapes,
                        texts: texts,
                        paintBackground: false,
                      ),
                    ),
                  )
                // No cache yet → full live painter
                else if (!hasCachedThumb && hasLiveContent)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ThumbnailPainter(
                        spec: page.spec,
                        strokes: strokes,
                        shapes: shapes,
                        texts: texts,
                        paintBackground: false,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: thumbW,
            child: Row(children: [
              Expanded(
                child: Text(
                  '${widget.index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 9.5,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w500,
                    color: widget.selected ? t.accent : t.inkFaint,
                  ),
                ),
              ),
              GestureDetector(
                onPanDown: (_) => HapticFeedback.lightImpact(),
                child: ReorderableDragStartListener(
                  index: widget.index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 13,
                      color: t.inkFaint,
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ThumbnailPainter — draws background pattern + committed strokes at scale
// ─────────────────────────────────────────────────────────────────────────────
class _ThumbnailPainter extends CustomPainter {
  _ThumbnailPainter({
    required this.spec,
    required this.strokes,
    required this.shapes,
    required this.texts,
    this.paintBackground = true,
  });

  final PageSpec spec;
  final List<Stroke> strokes;
  final List<ShapeObject> shapes;
  final List<TextBoxObject> texts;
  final bool paintBackground;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;

    if (paintBackground) {
      canvas.save();
      canvas.scale(sx, sy);
      BackgroundPainter(background: spec.background)
          .paint(canvas, Size(spec.widthPt, spec.heightPt));
      canvas.restore();
    }

    // Interleave shapes + non-tape strokes by createdAt to mirror the
    // canvas's combined Layer-1 z-order.
    final entries = <(DateTime, int, dynamic)>[];
    for (final s in strokes) {
      if (s.deleted) continue;
      entries.add((s.createdAt, 0, s));
    }
    for (final s in shapes) {
      if (s.deleted) continue;
      entries.add((s.createdAt, 1, s));
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    for (final e in entries) {
      if (e.$2 == 0) {
        _paintStroke(canvas, e.$3 as Stroke, sx, sy);
      } else {
        _paintShape(canvas, e.$3 as ShapeObject, sx, sy);
      }
    }
    // Text on top.
    for (final t in texts) {
      if (t.deleted) continue;
      _paintText(canvas, t, sx, sy);
    }
  }

  void _paintStroke(Canvas canvas, Stroke s, double sx, double sy) {
    if (s.points.length < 2) return;
    final paint = Paint()
      ..color = Color(s.colorArgb).withValues(alpha: s.opacity)
      ..strokeWidth = (s.widthPt * sx).clamp(0.4, 8.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(s.points.first.x * sx, s.points.first.y * sy);
    for (final pt in s.points.skip(1)) {
      path.lineTo(pt.x * sx, pt.y * sy);
    }
    canvas.drawPath(path, paint);
  }

  void _paintShape(Canvas canvas, ShapeObject s, double sx, double sy) {
    final rect = Rect.fromLTRB(
      s.bbox.minX * sx, s.bbox.minY * sy,
      s.bbox.maxX * sx, s.bbox.maxY * sy,
    );
    final strokePaint = Paint()
      ..color = Color(s.colorArgb)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s.strokeWidthPt * sx).clamp(0.4, 4.0);
    if (s.shape == ShapeKind.arrow) {
      _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, strokePaint);
      return;
    }
    if (s.shape == ShapeKind.line) {
      final a = Offset(
        s.arrowFlipX ? rect.right : rect.left,
        s.arrowFlipY ? rect.bottom : rect.top,
      );
      final b = Offset(
        s.arrowFlipX ? rect.left : rect.right,
        s.arrowFlipY ? rect.top : rect.bottom,
      );
      canvas.drawLine(a, b, strokePaint);
      return;
    }
    if (s.filled) {
      final fc = s.fillColorArgb != null ? Color(s.fillColorArgb!) : Color(s.colorArgb);
      _drawShapeKind(canvas, s.shape, rect,
          Paint()..color = fc..style = PaintingStyle.fill);
    }
    _drawShapeKind(canvas, s.shape, rect, strokePaint);
  }

  static void _drawArrow(
      Canvas canvas, Rect rect, bool flipX, bool flipY, Paint stroke) {
    final tail = Offset(
      flipX ? rect.right : rect.left,
      flipY ? rect.bottom : rect.top,
    );
    final head = Offset(
      flipX ? rect.left : rect.right,
      flipY ? rect.top : rect.bottom,
    );
    final dx = head.dx - tail.dx;
    final dy = head.dy - tail.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    const headLen = 18.0;
    const headW = 9.0;
    final bx = head.dx - ux * headLen;
    final by = head.dy - uy * headLen;
    final perpX = -uy * headW;
    final perpY = ux * headW;
    canvas.drawLine(tail, head, stroke);
    canvas.drawLine(head, Offset(bx + perpX, by + perpY), stroke);
    canvas.drawLine(head, Offset(bx - perpX, by - perpY), stroke);
  }

  static void _drawShapeKind(
      Canvas canvas, ShapeKind kind, Rect rect, Paint paint) {
    switch (kind) {
      case ShapeKind.rectangle:
        canvas.drawRect(rect, paint);
      case ShapeKind.ellipse:
        canvas.drawOval(rect, paint);
      case ShapeKind.triangle:
        final p = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();
        canvas.drawPath(p, paint);
      case ShapeKind.diamond:
        final p = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(p, paint);
      case ShapeKind.arrow:
      case ShapeKind.line:
        break; // handled before this switch
    }
  }

  void _paintText(Canvas canvas, TextBoxObject t, double sx, double sy) {
    final fontWeight = FontWeight.values.firstWhere(
      (w) => w.value == t.fontWeight,
      orElse: () => FontWeight.normal,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          color: Color(t.colorArgb),
          fontSize: t.fontSizePt * sx,
          fontWeight: fontWeight,
          fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
          fontFamily: t.fontFamily,
          height: 1.35,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    final w = (t.bbox.maxX - t.bbox.minX) * sx;
    tp.layout(maxWidth: w);
    tp.paint(canvas, Offset(t.bbox.minX * sx, t.bbox.minY * sy));
  }

  @override
  bool shouldRepaint(_ThumbnailPainter old) =>
      !identical(old.strokes, strokes) ||
      !identical(old.shapes, shapes) ||
      !identical(old.texts, texts) ||
      old.spec != spec ||
      old.paintBackground != paintBackground;
}

// Loads an asset image asynchronously and paints it fill-sized.
/// Render a PDF page at thumbnail size from the locally-stored asset.
class _AsyncThumbnailPdf extends StatefulWidget {
  const _AsyncThumbnailPdf({
    required this.assetId,
    required this.pageNo,
  });
  final String assetId;
  final int pageNo;

  @override
  State<_AsyncThumbnailPdf> createState() => _AsyncThumbnailPdfState();
}

class _AsyncThumbnailPdfState extends State<_AsyncThumbnailPdf> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AsyncThumbnailPdf old) {
    super.didUpdateWidget(old);
    if (old.assetId != widget.assetId) {
      _file = null;
      _load();
    }
  }

  Future<void> _load() async {
    final f = await AssetService().fileFor(widget.assetId);
    if (mounted) setState(() => _file = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_file == null) return const ColoredBox(color: Colors.white);
    return PdfDocumentViewBuilder.file(
      _file!.path,
      autoDispose: false,
      builder: (ctx, document) {
        if (document == null) return const ColoredBox(color: Colors.white);
        return PdfPageView(
          document: document,
          pageNumber: widget.pageNo,
          // Thumbnails don't need huge resolution.
          maximumDpi: 144,
          decoration: const BoxDecoration(color: Colors.white),
        );
      },
    );
  }
}

class _AsyncThumbnailImage extends StatefulWidget {
  const _AsyncThumbnailImage({required this.assetId});
  final String assetId;

  @override
  State<_AsyncThumbnailImage> createState() => _AsyncThumbnailImageState();
}

class _AsyncThumbnailImageState extends State<_AsyncThumbnailImage> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AsyncThumbnailImage old) {
    super.didUpdateWidget(old);
    if (old.assetId != widget.assetId) {
      _file = null;
      _load();
    }
  }

  Future<void> _load() async {
    final f = await AssetService().fileFor(widget.assetId);
    if (mounted) setState(() => _file = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_file == null) {
      return const ColoredBox(color: Colors.white);
    }
    return Image.file(_file!, fit: BoxFit.fill, gaplessPlayback: true);
  }
}
