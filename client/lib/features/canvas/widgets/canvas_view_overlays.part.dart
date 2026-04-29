part of 'canvas_view.dart';

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

    if (isPen) {
      final color = (fillColor ?? const Color(0xFF333333)).withValues(alpha: 1.0);
      final luminance = color.computeLuminance();
      final halo = luminance > 0.55
          ? const Color(0x88000000)
          : const Color(0xCCFFFFFF);

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

      const armLen = 6.0;
      const gap = 1.5;
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

    canvas.drawCircle(
      center, r,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor!,
    );
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
