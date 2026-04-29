/// Pure-Dart parser for GoodNotes 5/6 (.goodnotes) packages.
///
/// Usage:
/// ```dart
/// final doc = await GoodNotesDocument.openFile('/path/to/file.goodnotes');
/// for (final page in doc.pages) {
///   for (final el in page.elements) {
///     if (el is StrokeElement) print('stroke ${el.points.length} pts');
///     if (el is TextElement)   print('text  "${el.text}"');
///   }
/// }
/// ```
library goodnotes_parser;

export 'src/document.dart';
export 'src/model.dart';
export 'src/lz4_block.dart' show lz4BlockDecode;
export 'src/bv41.dart' show Bv41;
export 'src/tpl.dart' show TplPayload, TplPoint, TplSegment;
export 'src/protobuf.dart' show PbReader, PbField, PbWireType;
export 'src/svg_renderer.dart' show SvgRenderer;
