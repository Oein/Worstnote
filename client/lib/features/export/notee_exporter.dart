// NoteeExporter — serialises a NotebookState to a .notee ZIP file.
// Format:
//   meta.json          — note metadata
//   pages.json         — page list
//   layers.json        — layers per page
//   strokes.json       — strokes per page
//   shapes.json        — shapes per page
//   texts.json         — text boxes per page
//   active_layers.json — active layer id per page
//   assets/<id>        — binary asset files (image / PDF backgrounds)

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import 'export_helper.dart';

import '../../domain/page_spec.dart';
import '../import/asset_service.dart';
import '../notebook/notebook_state.dart';

class NoteeExporter {
  /// Shows a progress dialog, serialises the state, and presents the OS save
  /// dialog. Returns the saved path, or null if cancelled.
  static Future<String?> exportNoteWithProgress(
    BuildContext context,
    NotebookState state, {
    String? suggestedName,
  }) async {
    final statusNotifier = ValueNotifier<String>('저장 중…');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<String>(
        valueListenable: statusNotifier,
        builder: (_, msg, __) => AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(msg)),
            ],
          ),
        ),
      ),
    );

    try {
      final bytes = await buildNoteeBytes(
        state,
        onStatus: (s) => statusNotifier.value = s,
      );

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      final safeName = (suggestedName ?? state.note.title)
          .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      return await platformSaveBytes(
        bytes,
        suggestedName: safeName,
        extension: 'worstnote',
        typeLabel: 'Worstnote 파일',
      );
    } catch (_) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      rethrow;
    } finally {
      statusNotifier.dispose();
    }
  }

  static Future<Uint8List> buildNoteeBytes(
    NotebookState state, {
    void Function(String)? onStatus,
  }) async {
    final archive = Archive();

    onStatus?.call('메타데이터 저장 중…');
    _addJson(archive, 'meta.json', {'version': 1, 'note': state.note.toJson()});
    _addJson(archive, 'pages.json',
        state.pages.map((p) => p.toJson()).toList());
    _addJson(archive, 'layers.json', {
      for (final e in state.layersByPage.entries)
        e.key: e.value.map((l) => l.toJson()).toList(),
    });
    _addJson(archive, 'strokes.json', {
      for (final e in state.strokesByPage.entries)
        e.key: e.value.map((s) => s.toJson()).toList(),
    });
    _addJson(archive, 'shapes.json', {
      for (final e in state.shapesByPage.entries)
        e.key: e.value.map((s) => s.toJson()).toList(),
    });
    _addJson(archive, 'texts.json', {
      for (final e in state.textsByPage.entries)
        e.key: e.value.map((t) => t.toJson()).toList(),
    });
    _addJson(archive, 'active_layers.json', state.activeLayerByPage);

    onStatus?.call('애셋 번들 중…');
    final assetService = AssetService();
    final bundled = <String>{};
    for (final page in state.pages) {
      final bg = page.spec.background;
      String? assetId;
      if (bg is ImageBackground) assetId = bg.assetId;
      if (bg is PdfBackground) assetId = bg.assetId;
      if (assetId != null && bundled.add(assetId)) {
        final file = await assetService.fileFor(assetId);
        if (file != null) {
          final bytes = await file.readAsBytes();
          archive
              .addFile(ArchiveFile('assets/$assetId', bytes.length, bytes));
        }
      }
    }

    return Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
  }

  static void _addJson(Archive archive, String name, Object data) {
    final bytes = utf8.encode(jsonEncode(data));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
}
