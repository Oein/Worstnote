// Page-level layout description: physical size + background style.
//
// A page always carries its own [PageSpec] (vs only the note default), so a
// single note can mix sizes — necessary for PDF imports where each page may
// have a different native size.

import 'package:freezed_annotation/freezed_annotation.dart';

part 'page_spec.freezed.dart';
part 'page_spec.g.dart';

enum PaperKind { a3, a4, a5, b3, b4, b5, letter, square, custom, pdfImported }

/// Common paper dimensions in pt (1pt = 1/72 inch), portrait orientation.
/// Provided as `(width, height)` records to avoid a dependency on `dart:ui`.
class PaperDimensions {
  // ISO A-series
  static const (double, double) a3 = (841.89, 1190.55);
  static const (double, double) a4 = (595.276, 841.89);
  static const (double, double) a5 = (419.528, 595.276);
  // ISO B-series
  static const (double, double) b3 = (1000.630, 1417.323);
  static const (double, double) b4 = (708.661, 1000.630);
  static const (double, double) b5 = (498.898, 708.661);
  // Other
  static const (double, double) letter = (612.0, 792.0);
  static const (double, double) square = (595.276, 595.276);

  /// Returns portrait (width, height) for [kind]. Falls back to A4.
  static (double, double) forKind(PaperKind kind) => switch (kind) {
    PaperKind.a3 => a3,
    PaperKind.a4 => a4,
    PaperKind.a5 => a5,
    PaperKind.b3 => b3,
    PaperKind.b4 => b4,
    PaperKind.b5 => b5,
    PaperKind.letter => letter,
    PaperKind.square => square,
    _ => a4,
  };
}

@Freezed(unionKey: 'kind')
sealed class PageBackground with _$PageBackground {
  const factory PageBackground.blank() = BlankBackground;

  const factory PageBackground.grid({required double spacingPt}) =
      GridBackground;

  const factory PageBackground.ruled({required double spacingPt}) =
      RuledBackground;

  const factory PageBackground.dot({required double spacingPt}) =
      DotBackground;

  const factory PageBackground.image({required String assetId}) =
      ImageBackground;

  const factory PageBackground.pdf({
    required String assetId,
    required int pageNo,
  }) = PdfBackground;

  factory PageBackground.fromJson(Map<String, dynamic> json) =>
      _$PageBackgroundFromJson(json);
}

@freezed
class PageSpec with _$PageSpec {
  const factory PageSpec({
    required double widthPt,
    required double heightPt,
    required PaperKind kind,
    required PageBackground background,
  }) = _PageSpec;

  factory PageSpec.fromJson(Map<String, dynamic> json) =>
      _$PageSpecFromJson(json);

  /// Pre-baked A4 portrait blank page.
  factory PageSpec.a4Blank() => const PageSpec(
        widthPt: 595.276,
        heightPt: 841.89,
        kind: PaperKind.a4,
        background: PageBackground.blank(),
      );

  /// Letter-sized blank page.
  factory PageSpec.letterBlank() => const PageSpec(
        widthPt: 612,
        heightPt: 792,
        kind: PaperKind.letter,
        background: PageBackground.blank(),
      );
}
