import 'dart:typed_data';

import 'tpl.dart';

/// 4-component RGBA color. Each channel is 0..1.
class Color4 {
  final double r, g, b, a;
  const Color4(this.r, this.g, this.b, this.a);
  Color4.fromBytes(int rByte, int gByte, int bByte, int aByte)
      : r = rByte / 255.0,
        g = gByte / 255.0,
        b = bByte / 255.0,
        a = aByte / 255.0;
  /// 0xAARRGGBB (compatible with Flutter's Color(...) integer arg).
  int toArgb() {
    int c(double v) => (v.clamp(0.0, 1.0) * 255).round() & 0xff;
    return (c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
  }

  @override
  String toString() => 'Color4(${r.toStringAsFixed(3)}, '
      '${g.toStringAsFixed(3)}, ${b.toStringAsFixed(3)}, '
      '${a.toStringAsFixed(3)})';
}

/// Axis-aligned bounding box in page-point coordinates.
class BBox {
  final double minX, minY, maxX, maxY;
  const BBox(this.minX, this.minY, this.maxX, this.maxY);
  double get width => maxX - minX;
  double get height => maxY - minY;
  @override
  String toString() => 'BBox($minX, $minY → $maxX, $maxY)';
}

/// Common interface for any visual element on a page.
sealed class PageElement {
  /// UUID — unique within the document.
  final String id;
  /// `op_type` from the GoodNotes change-log header (1=stroke, 2=text/shape, …).
  final int opType;
  /// Element BBox (page coordinates).
  final BBox? bbox;
  /// Lamport clock from the source change-log record (creation order).
  final int lamport;

  PageElement({
    required this.id,
    required this.opType,
    required this.lamport,
    this.bbox,
  });
}

/// A pen / highlighter stroke.
class StrokeElement extends PageElement {
  final Color4 color;
  /// Width as encoded in the BODY proto (`#15`). This matches the TPL
  /// payload width when present.
  final double width;
  /// Decoded TPL payload — `points`, `pressures`, etc.
  final TplPayload? payload;
  /// Whether the stroke has an arrowhead at the end (schema-31 arrow shapes).
  final bool arrowEnd;

  StrokeElement({
    required super.id,
    required super.opType,
    required super.lamport,
    super.bbox,
    required this.color,
    required this.width,
    this.payload,
    this.arrowEnd = false,
  });

  /// Stroke points in draw order (anchors + each segment endpoint).
  List<TplPoint> get points => payload?.flatPoints() ?? const [];

  @override
  String toString() => 'StrokeElement(id=$id, points=${points.length}, '
      'color=$color, width=$width)';
}

/// A text box.
class TextElement extends PageElement {
  /// Plain text content (UTF-8).
  final String text;
  final Color4 color;
  /// Font size in points.
  final double fontSize;
  /// Optional letter spacing.
  final double? letterSpacing;
  /// Background fill color for the text box frame, or null if transparent.
  final Color4? fillColor;
  /// Corner radius for the background rect (0 = sharp corners).
  final double cornerRadius;
  /// When this element is embedded in a container, this holds the container's
  /// full page bbox (used to draw the container background rect). bbox itself
  /// holds the element's own translated page position for text placement.
  final BBox? containerBbox;

  TextElement({
    required super.id,
    required super.opType,
    required super.lamport,
    super.bbox,
    required this.text,
    required this.color,
    required this.fontSize,
    this.letterSpacing,
    this.fillColor,
    this.cornerRadius = 0,
    this.containerBbox,
  });

  @override
  String toString() => 'TextElement(id=$id, "${text.substring(0,
      text.length > 30 ? 30 : text.length)}", size=$fontSize)';
}

/// An image / PDF embedded as an inline element on the page (vs the page
/// background itself). The [attachmentId] points into
/// [GoodNotesDocument.attachments].
class ImageElement extends PageElement {
  final String attachmentId;
  ImageElement({
    required super.id,
    required super.opType,
    required super.lamport,
    super.bbox,
    required this.attachmentId,
  });

  @override
  String toString() =>
      'ImageElement(id=$id, attachment=$attachmentId, bbox=$bbox)';
}

/// Anything we couldn't classify (unknown shape / inline attachment etc).
/// The raw BODY proto bytes are kept so callers can inspect or recover.
class UnknownElement extends PageElement {
  final Uint8List rawBody;
  UnknownElement({
    required super.id,
    required super.opType,
    required super.lamport,
    super.bbox,
    required this.rawBody,
  });

  @override
  String toString() => 'UnknownElement(id=$id, op=$opType, '
      'rawBody=${rawBody.length}B)';
}

/// One page of the document.
class Page {
  /// Page UUID.
  final String id;
  /// Background attachment (PDF or PNG) UUID — `null` if blank page.
  final String? backgroundAttachmentId;
  /// All elements on the page in change-log order.
  final List<PageElement> elements;
  /// Schema version that wrote this page (24 or 31 observed).
  final int schemaVersion;

  Page({
    required this.id,
    this.backgroundAttachmentId,
    required this.elements,
    required this.schemaVersion,
  });

  Iterable<StrokeElement> get strokes =>
      elements.whereType<StrokeElement>();
  Iterable<TextElement> get texts => elements.whereType<TextElement>();

  @override
  String toString() => 'Page(id=$id, ${elements.length} elements, '
      'bg=$backgroundAttachmentId)';
}

/// One attachment file (image / PDF) embedded in the package.
class Attachment {
  /// Attachment key UUID (as stored in `index.attachments.pb`).
  final String id;
  /// Filename UUID under `attachments/` (often == id but not always).
  final String diskUuid;
  /// Raw bytes — usually a complete PDF or PNG.
  final Uint8List bytes;

  Attachment({
    required this.id,
    required this.diskUuid,
    required this.bytes,
  });

  /// `true` if the bytes start with `%PDF-`.
  bool get isPdf =>
      bytes.length > 4 && bytes[0] == 0x25 && bytes[1] == 0x50 &&
      bytes[2] == 0x44 && bytes[3] == 0x46;

  /// `true` if the bytes start with the PNG magic.
  bool get isPng =>
      bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 &&
      bytes[2] == 0x4e && bytes[3] == 0x47;

  String get mimeType => isPdf ? 'application/pdf' : (isPng ? 'image/png'
      : 'application/octet-stream');

  @override
  String toString() => 'Attachment(id=$id, $mimeType, ${bytes.length}B)';
}

/// One OCR token.
class SearchToken {
  final String text;
  /// Glyph runs — each contains the substring offset, length, and a bbox.
  final List<GlyphRun> glyphRuns;
  SearchToken(this.text, this.glyphRuns);
  @override
  String toString() => 'SearchToken($text, ${glyphRuns.length} runs)';
}

class GlyphRun {
  final int charOffset;
  final int charCount;
  final BBox? bbox;
  GlyphRun(this.charOffset, this.charCount, this.bbox);
}

class SearchIndex {
  /// Either a page UUID or attachment UUID, depending on [forAttachment].
  final String targetId;
  final bool forAttachment;
  final List<SearchToken> tokens;
  SearchIndex({
    required this.targetId,
    required this.forAttachment,
    required this.tokens,
  });
}
