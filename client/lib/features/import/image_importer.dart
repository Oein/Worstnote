// Image importer: pick an image, store via [AssetService], return a
// [PageSpec] suited to the image (custom dimensions + image background).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import '../../domain/page_spec.dart';
import 'asset_service.dart';

class ImportedImage {
  ImportedImage(this.assetRef, this.spec);
  final AssetRef assetRef;
  final PageSpec spec;
}

class ImageImporter {
  ImageImporter({AssetService? service}) : _service = service ?? AssetService();
  final AssetService _service;

  /// Returns null if the user cancelled the picker.
  Future<ImportedImage?> pickAndImport() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final ref = await _service.putBytes(bytes, mime: file.mimeType ?? 'image/png');
    final dim = await _decodeDim(ref.file);
    return ImportedImage(
      ref,
      PageSpec(
        widthPt: dim.width.toDouble(),
        heightPt: dim.height.toDouble(),
        kind: PaperKind.custom,
        background: PageBackground.image(assetId: ref.id),
      ),
    );
  }

  Future<({int width, int height})> _decodeDim(File f) async {
    final bytes = await f.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();
    return (width: w, height: h);
  }
}

