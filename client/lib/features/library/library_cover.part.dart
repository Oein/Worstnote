part of 'library_screen.dart';

// ── Notebook cover ─────────────────────────────────────────────────────
// Shows the first page's background pattern as the cover thumbnail.
// A star button (top-right) toggles favorite status instantly.
class _NotebookCover extends ConsumerWidget {
  const _NotebookCover({
    required this.note,
    required this.onTap,
    this.onLongPress,
    this.onContextMenu,
  });
  final NoteSummary note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final spec = note.firstPageSpec;
    final pageAspect = (spec != null && spec.heightPt > 0)
        ? spec.widthPt / spec.heightPt
        : 0.74;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!.call(d.globalPosition),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: pageAspect,
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.page,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(color: t.pageEdge, spreadRadius: 0.5),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.07),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(children: [
                    Positioned.fill(child: _CoverContent(note: note)),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _CloudBadge(noteId: note.id),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: GestureDetector(
                        onTap: () => ref
                            .read(libraryProvider.notifier)
                            .toggleFavorite(note.id),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: note.isFavorite
                                ? Colors.amber.withValues(alpha: 0.22)
                                : Colors.black.withValues(alpha: 0.10),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            note.isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 14,
                            color: note.isFavorite
                                ? Colors.amber
                                : Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '${note.pageCount} pages · ${_relTime(note.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 11,
                color: t.inkDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Unified cover content ─────────────────────────────────────────────
// Tries to show a pre-generated PNG thumbnail from ThumbnailService.
// Falls back to live painters while the cache is cold or not yet generated.
class _CoverContent extends StatefulWidget {
  const _CoverContent({required this.note});
  final NoteSummary note;

  @override
  State<_CoverContent> createState() => _CoverContentState();
}

class _CoverContentState extends State<_CoverContent> {
  Uint8List? _bytes;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = ThumbnailService.instance.onCoverGenerated.listen((noteId) {
      if (mounted && noteId == widget.note.id && _bytes == null) _load();
    });
  }

  @override
  void didUpdateWidget(_CoverContent old) {
    super.didUpdateWidget(old);
    if (old.note.id != widget.note.id) {
      _bytes = null;
      _load();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final bytes = await ThumbnailService.instance.getCached(widget.note.id);
    if (mounted && bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.fill);
    }

    final note = widget.note;
    final spec = note.firstPageSpec;
    final bg = spec?.background ?? const PageBackground.blank();
    return Stack(children: [
      Positioned.fill(
        child: CustomPaint(painter: BackgroundPainter(background: bg)),
      ),
      if (bg is ImageBackground || bg is PdfBackground)
        Positioned.fill(
          child: LayoutBuilder(
            builder: (_, c) => BackgroundImageLayer(
              background: bg,
              size: Size(c.maxWidth, c.maxHeight),
            ),
          ),
        ),
      if (spec != null) ...[
        if (note.firstPageStrokes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverStrokesPainter(
                  spec: spec, strokes: note.firstPageStrokes),
            ),
          ),
        if (note.firstPageShapes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverShapesPainter(
                  spec: spec, shapes: note.firstPageShapes),
            ),
          ),
        if (note.firstPageTexts.isNotEmpty)
          Positioned.fill(
            child: _CoverTextsPainter(
                spec: spec, texts: note.firstPageTexts),
          ),
        if (note.firstPageStrokes.any((s) => !s.deleted && s.tool == ToolKind.tape))
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverTapePainter(
                  spec: spec, strokes: note.firstPageStrokes),
            ),
          ),
      ],
    ]);
  }
}

// ── Cover strokes painter ─────────────────────────────────────────────
class _CoverStrokesPainter extends CustomPainter {
  const _CoverStrokesPainter({required this.spec, required this.strokes});

  final PageSpec spec;
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    _paintPass(canvas, sx, sy, tapeOnly: false);
    _paintPass(canvas, sx, sy, tapeOnly: true);
  }

  void _paintPass(Canvas canvas, double sx, double sy, {required bool tapeOnly}) {
    for (final stroke in strokes) {
      if (stroke.deleted || stroke.points.length < 2) continue;
      final isTape = stroke.tool == ToolKind.tape;
      if (tapeOnly && !isTape) continue;
      if (!tapeOnly && isTape) continue;
      final paint = Paint()
        ..color = Color(stroke.colorArgb).withValues(alpha: isTape ? 1.0 : stroke.opacity)
        ..strokeWidth = isTape
            ? (stroke.widthPt * sx).clamp(0.4, double.infinity)
            : (stroke.widthPt * sx).clamp(0.4, 6.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(stroke.points.first.x * sx, stroke.points.first.y * sy);
      for (final pt in stroke.points.skip(1)) {
        path.lineTo(pt.x * sx, pt.y * sy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CoverStrokesPainter old) =>
      !identical(old.strokes, strokes) || old.spec != spec;
}

class _CoverTapePainter extends CustomPainter {
  const _CoverTapePainter({required this.spec, required this.strokes});

  final PageSpec spec;
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    for (final s in strokes) {
      if (s.deleted || s.points.length < 2 || s.tool != ToolKind.tape) continue;
      final paint = Paint()
        ..color = Color(s.colorArgb)
        ..strokeWidth = (s.widthPt * sx).clamp(0.4, double.infinity)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(s.points.first.x * sx, s.points.first.y * sy);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * sx, pt.y * sy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CoverTapePainter old) =>
      !identical(old.strokes, strokes) || old.spec != spec;
}

class _CoverShapesPainter extends CustomPainter {
  const _CoverShapesPainter({required this.spec, required this.shapes});

  final PageSpec spec;
  final List<ShapeObject> shapes;

  @override
  void paint(Canvas canvas, Size size) {
    if (shapes.isEmpty) return;
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    canvas.save();
    canvas.scale(sx, sy);
    for (final s in shapes) {
      if (s.deleted) continue;
      final rect = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      final sp = Paint()
        ..color = Color(s.colorArgb)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.strokeWidthPt
        ..isAntiAlias = true;
      if (s.shape == ShapeKind.arrow) {
        _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, sp);
        continue;
      }
      if (s.shape == ShapeKind.line) {
        final aPt = Offset(
          s.arrowFlipX ? rect.right : rect.left,
          s.arrowFlipY ? rect.bottom : rect.top,
        );
        final bPt = Offset(
          s.arrowFlipX ? rect.left : rect.right,
          s.arrowFlipY ? rect.top : rect.bottom,
        );
        canvas.drawLine(aPt, bPt, sp);
        continue;
      }
      if (s.filled) {
        final fc = s.fillColorArgb != null ? Color(s.fillColorArgb!) : Color(s.colorArgb);
        final fp = Paint()..color = fc..style = PaintingStyle.fill..isAntiAlias = true;
        switch (s.shape) {
          case ShapeKind.rectangle:
            canvas.drawRect(rect, fp);
          case ShapeKind.ellipse:
            canvas.drawOval(rect, fp);
          case ShapeKind.triangle:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.bottom)
              ..lineTo(rect.left, rect.bottom)
              ..close(), fp);
          case ShapeKind.diamond:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.center.dy)
              ..lineTo(rect.center.dx, rect.bottom)
              ..lineTo(rect.left, rect.center.dy)
              ..close(), fp);
          case ShapeKind.arrow:
          case ShapeKind.line:
            break;
        }
      }
      switch (s.shape) {
        case ShapeKind.rectangle:
          canvas.drawRect(rect, sp);
        case ShapeKind.ellipse:
          canvas.drawOval(rect, sp);
        case ShapeKind.triangle:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.diamond:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.center.dy)
            ..lineTo(rect.center.dx, rect.bottom)
            ..lineTo(rect.left, rect.center.dy)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.arrow:
        case ShapeKind.line:
          break;
      }
    }
    canvas.restore();
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

  @override
  bool shouldRepaint(_CoverShapesPainter old) =>
      !identical(old.shapes, shapes) || old.spec != spec;
}

class _CoverTextsPainter extends StatelessWidget {
  const _CoverTextsPainter({required this.spec, required this.texts});

  final PageSpec spec;
  final List<TextBoxObject> texts;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final sx = constraints.maxWidth / spec.widthPt;
        final sy = constraints.maxHeight / spec.heightPt;
        return CustomPaint(
          painter: _CoverTextsCanvasPainter(spec: spec, texts: texts, sx: sx, sy: sy),
        );
      },
    );
  }
}

class _CoverTextsCanvasPainter extends CustomPainter {
  const _CoverTextsCanvasPainter({
    required this.spec,
    required this.texts,
    required this.sx,
    required this.sy,
  });

  final PageSpec spec;
  final List<TextBoxObject> texts;
  final double sx, sy;

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in texts) {
      if (t.deleted || t.text.isEmpty) continue;
      final x = t.bbox.minX * sx;
      final y = t.bbox.minY * sy;
      final w = (t.bbox.maxX - t.bbox.minX) * sx;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontSize: (t.fontSizePt * sy).clamp(6.0, 24.0),
            color: Color(t.colorArgb),
            fontFamily: t.fontFamily,
            fontWeight: FontWeight.values.firstWhere(
              (fw) => fw.value == t.fontWeight,
              orElse: () => FontWeight.w400,
            ),
            fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 5,
        ellipsis: '…',
      )
        ..layout(maxWidth: w.clamp(10.0, double.infinity));
      tp.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(_CoverTextsCanvasPainter old) =>
      !identical(old.texts, texts) || old.sx != sx || old.sy != sy;
}
