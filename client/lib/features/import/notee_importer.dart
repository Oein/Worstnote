// NoteeImporter — deserialises a .notee ZIP file back into a NotebookState.
// Assets embedded in assets/<id> are written into the local AssetService so
// that page backgrounds render correctly after import.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show Size;
import 'package:pdfrx/pdfrx.dart';

import '../../domain/layer.dart';
import '../../domain/note.dart';
import '../../domain/page.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../notebook/notebook_state.dart';
import 'asset_service.dart';
import 'pdf_render_cache.dart';

class NoteeImporter {
  NoteeImporter({AssetService? service}) : _service = service ?? AssetService();
  final AssetService _service;

  /// Opens a file picker for .notee files and imports the chosen file.
  /// Returns null on cancel or parse error.
  Future<NotebookState?> pickAndImport() async {
    const group = XTypeGroup(
      label: 'Worstnote 파일',
      extensions: ['worstnote', 'notee'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return null;
    return importBytes(await file.readAsBytes());
  }

  Future<NotebookState?> importBytes(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    dynamic parseJson(String name) {
      final f = archive.findFile(name);
      if (f == null) throw FormatException('Missing $name in .notee file');
      return jsonDecode(utf8.decode(f.content as Uint8List));
    }

    final meta = parseJson('meta.json') as Map<String, dynamic>;
    final note = Note.fromJson(meta['note'] as Map<String, dynamic>);

    final pages = (parseJson('pages.json') as List)
        .map((j) => NotePage.fromJson(j as Map<String, dynamic>))
        .toList();

    final layersByPage =
        (parseJson('layers.json') as Map<String, dynamic>).map((k, v) =>
            MapEntry(
              k,
              (v as List)
                  .map((j) => Layer.fromJson(j as Map<String, dynamic>))
                  .toList(),
            ));

    final strokesByPage =
        (parseJson('strokes.json') as Map<String, dynamic>).map((k, v) =>
            MapEntry(
              k,
              (v as List)
                  .map((j) => Stroke.fromJson(j as Map<String, dynamic>))
                  .toList(),
            ));

    final shapesByPage =
        (parseJson('shapes.json') as Map<String, dynamic>).map((k, v) =>
            MapEntry(
              k,
              (v as List)
                  .map((j) => ShapeObject.fromJson(j as Map<String, dynamic>))
                  .toList(),
            ));

    final textsByPage =
        (parseJson('texts.json') as Map<String, dynamic>).map((k, v) =>
            MapEntry(
              k,
              (v as List)
                  .map((j) => TextBoxObject.fromJson(j as Map<String, dynamic>))
                  .toList(),
            ));

    final activeLayerByPage =
        (parseJson('active_layers.json') as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as String));

    // Restore bundled assets that aren't already in the local store.
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith('assets/')) continue;
      final assetId = f.name.substring('assets/'.length);
      if (assetId.isEmpty) continue;
      final existing = await _service.fileFor(assetId);
      if (existing == null) {
        final content = f.content as Uint8List;
        await _service.putBytes(content, mime: _guessMime(content));
      }
    }

    // Pre-render every imported PDF page at all four scales in the
    // background, so the canvas can show 200%+ immediately when opened
    // (otherwise the user sees the 25% placeholder until each visible
    // page is requested).
    await _enqueuePdfRenders(pages);

    return NotebookState(
      note: note,
      pages: pages,
      layersByPage: layersByPage,
      strokesByPage: strokesByPage,
      shapesByPage: shapesByPage,
      textsByPage: textsByPage,
      activeLayerByPage: activeLayerByPage,
    );
  }

  Future<void> _enqueuePdfRenders(List<NotePage> pages) async {
    final docSizes = <String, List<Size>>{};
    final seen = <String>{};
    for (final page in pages) {
      final bg = page.spec.background;
      if (bg is! PdfBackground) continue;
      final key = '${bg.assetId}#${bg.pageNo}';
      if (!seen.add(key)) continue;
      final file = await _service.fileFor(bg.assetId);
      if (file == null) continue;
      var sizes = docSizes[bg.assetId];
      if (sizes == null) {
        try {
          final doc = await PdfDocument.openFile(file.path);
          sizes = [
            for (final p in doc.pages) Size(p.width, p.height),
          ];
          await doc.dispose();
        } catch (_) {
          sizes = const [];
        }
        docSizes[bg.assetId] = sizes;
      }
      final idx = bg.pageNo - 1;
      if (idx < 0 || idx >= sizes.length) continue;
      PdfRenderCache.instance.enqueue(
        file,
        bg.assetId,
        bg.pageNo,
        sizes[idx],
        PdfRenderCache.allScales,
      );
    }
  }

  static String _guessMime(Uint8List b) {
    if (b.length >= 4 &&
        b[0] == 0x25 && b[1] == 0x50 &&
        b[2] == 0x44 && b[3] == 0x46) {
      return 'application/pdf';
    }
    return 'image/png';
  }
}
