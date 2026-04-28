// Inline-editable text boxes overlayed on the canvas.
//
// A text box has three modes:
//   - idle      → Text widget, alignment-aware, sized to bbox.width
//   - selected  → idle render + selection overlay (drawn elsewhere)
//   - editing   → TextField inside the same bbox; alignment + style match
//                 the idle render so there is no visual jump on commit
//
// The single source of truth is [TextBoxObject]: width is user-controlled
// (via the resize handle), height is auto-fit and re-measured on every
// property/text change via [withRemeasuredHeight].

import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';

import '../../../domain/page_object.dart';

/// Build the [TextStyle] for a [TextBoxObject]. Used by static rendering,
/// the editable [TextField], and [measureTextBoxHeight] so all three stay
/// in sync.
TextStyle textBoxStyle(TextBoxObject box) {
  final fontWeight = FontWeight.values.firstWhere(
    (w) => w.value == box.fontWeight,
    orElse: () => FontWeight.normal,
  );
  return TextStyle(
    color: Color(box.colorArgb),
    fontSize: box.fontSizePt,
    fontWeight: fontWeight,
    fontStyle: box.italic ? FontStyle.italic : FontStyle.normal,
    fontFamily: box.fontFamily,
    height: 1.35,
  );
}

/// Map [TextBoxObject.textAlign] (0/1/2) to Flutter's [TextAlign].
TextAlign textBoxAlign(TextBoxObject box) {
  switch (box.textAlign.clamp(0, 2)) {
    case 1:
      return TextAlign.center;
    case 2:
      return TextAlign.right;
    case 0:
    default:
      return TextAlign.left;
  }
}

/// Measure how tall [box] would render at [width] pixels wide.
double measureTextBoxHeight(TextBoxObject box, double width) {
  final tp = TextPainter(
    text: TextSpan(
      text: box.text.isEmpty ? ' ' : box.text,
      style: textBoxStyle(box),
    ),
    textDirection: ui.TextDirection.ltr,
    textAlign: textBoxAlign(box),
    maxLines: null,
  );
  tp.layout(maxWidth: width);
  // 4 pt slop covers the editable inset (vertical content padding).
  return tp.height + 4;
}

/// Return [box] with its bbox.maxY recomputed from the current text/width
/// /font properties. Width and minX/minY are preserved.
TextBoxObject withRemeasuredHeight(TextBoxObject box) {
  final w = box.bbox.maxX - box.bbox.minX;
  final h = measureTextBoxHeight(box, w);
  return box.copyWith(
    bbox: Bbox(
      minX: box.bbox.minX,
      minY: box.bbox.minY,
      maxX: box.bbox.maxX,
      maxY: box.bbox.minY + h,
    ),
  );
}

class TextLayer extends StatelessWidget {
  const TextLayer({
    super.key,
    required this.texts,
    required this.layerId,
    this.editingBoxId,
    this.onChanged,
  });

  final List<TextBoxObject> texts;
  final String layerId;
  final String? editingBoxId;
  final void Function(TextBoxObject)? onChanged;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (final t in texts)
          if (!t.deleted && t.layerId == layerId)
            _PositionedTextBox(
              key: ValueKey(t.id),
              box: t,
              editable: t.id == editingBoxId,
              onChanged: onChanged,
            ),
      ],
    );
  }
}

class _PositionedTextBox extends StatefulWidget {
  const _PositionedTextBox({
    super.key,
    required this.box,
    required this.editable,
    this.onChanged,
  });
  final TextBoxObject box;
  final bool editable;
  final void Function(TextBoxObject)? onChanged;

  @override
  State<_PositionedTextBox> createState() => _PositionedTextBoxState();
}

class _PositionedTextBoxState extends State<_PositionedTextBox> {
  late double _width;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _width = (widget.box.bbox.maxX - widget.box.bbox.minX)
        .clamp(60.0, double.infinity);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    if (widget.editable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  void _onFocusChange() {
    // When the editing TextField loses focus and the box is empty, delete
    // it — empty text boxes are clutter the user didn't commit anything to.
    if (widget.editable && !_focusNode.hasFocus) {
      if (widget.box.text.trim().isEmpty) {
        widget.onChanged?.call(
          widget.box.copyWith(deleted: true, rev: widget.box.rev + 1),
        );
      }
    }
  }

  @override
  void didUpdateWidget(_PositionedTextBox old) {
    super.didUpdateWidget(old);
    if (old.box.bbox != widget.box.bbox) {
      _width = (widget.box.bbox.maxX - widget.box.bbox.minX)
          .clamp(60.0, double.infinity);
    }
    if (!old.editable && widget.editable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } else if (old.editable && !widget.editable) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _width = (_width + d.delta.dx).clamp(60.0, double.infinity);
    });
  }

  void _onDragEnd(DragEndDetails _) {
    // Commit the new width and let the height resync to it.
    final widened = widget.box.copyWith(
      bbox: Bbox(
        minX: widget.box.bbox.minX,
        minY: widget.box.bbox.minY,
        maxX: widget.box.bbox.minX + _width,
        maxY: widget.box.bbox.maxY,
      ),
      rev: widget.box.rev + 1,
    );
    widget.onChanged?.call(withRemeasuredHeight(widened));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.box.bbox.minX,
      top: widget.box.bbox.minY,
      width: _width + (widget.editable ? 8 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _width,
            child: _TextBox(
              box: widget.box,
              editable: widget.editable,
              focusNode: widget.editable ? _focusNode : null,
              onChanged: widget.onChanged,
            ),
          ),
          if (widget.editable)
            GestureDetector(
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: Container(
                  width: 8,
                  height: 32,
                  alignment: Alignment.center,
                  child: Container(
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TextBox extends StatefulWidget {
  const _TextBox({
    required this.box,
    required this.editable,
    this.focusNode,
    this.onChanged,
  });
  final TextBoxObject box;
  final bool editable;
  final FocusNode? focusNode;
  final void Function(TextBoxObject)? onChanged;

  @override
  State<_TextBox> createState() => _TextBoxState();
}

class _TextBoxState extends State<_TextBox> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.box.text);
  }

  @override
  void didUpdateWidget(_TextBox old) {
    super.didUpdateWidget(old);
    if (old.box.text != widget.box.text && _ctl.text != widget.box.text) {
      _ctl.value = _ctl.value.copyWith(text: widget.box.text);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // Identical inset for the static Text and the TextField content so the
  // two render at the exact same baseline — no visual jump on edit/commit.
  static const EdgeInsets _textInset = EdgeInsets.fromLTRB(2, 2, 2, 2);

  @override
  Widget build(BuildContext context) {
    final style = textBoxStyle(widget.box);
    final align = textBoxAlign(widget.box);
    if (!widget.editable) {
      // Static render — alignment is meaningful only when the Text fills
      // the full box width, hence the wrapping SizedBox provided by the
      // parent _PositionedTextBox.
      return Padding(
        padding: _textInset,
        child: Text(_ctl.text, style: style, textAlign: align),
      );
    }
    // foregroundDecoration paints the outline on TOP of the TextField without
    // affecting layout — coordinates of the typed text stay identical to the
    // static Text render.
    return Container(
      foregroundDecoration: BoxDecoration(
        border: Border.all(
          color: const Color(0xFF2563EB).withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      child: TextField(
        controller: _ctl,
        focusNode: widget.focusNode,
        style: style,
        textAlign: align,
        maxLines: null,
        minLines: 1,
        selectionControls: materialTextSelectionControls,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: _textInset,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
        onChanged: (v) {
          final updated = widget.box.copyWith(text: v, rev: widget.box.rev + 1);
          widget.onChanged?.call(withRemeasuredHeight(updated));
        },
      ),
    );
  }
}
