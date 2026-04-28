// ImagesZipExporter — renders every page as a 2× PNG and bundles them
// into a ZIP file using the pdf package pipeline + pdfrx renderer.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../notebook/notebook_state.dart';
import 'export_helper.dart';
import 'pdf_exporter.dart';

class ImagesZipExporter {
  /// Shows a progress dialog, renders every page as PNG, zips them, and
  /// presents the OS save dialog. Returns the saved path, or null if cancelled.
  static Future<String?> exportNoteWithProgress(
    BuildContext context,
    NotebookState state, {
    String? suggestedName,
  }) async {
    final progress = ValueNotifier<({int current, int total})>(
        (current: 0, total: state.pages.length));

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<({int current, int total})>(
        valueListenable: progress,
        builder: (_, v, __) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('이미지 변환 중… (${v.current}/${v.total})'),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: v.total > 0 ? v.current / v.total : 0,
              ),
            ],
          ),
        ),
      ),
    );

    try {
      // Build PDF bytes first (reuses existing vector rendering pipeline).
      final pdfBytes = await PdfExporter.buildPdfBytes(state);

      // Render each PDF page to PNG via pdfrx.
      final archive = Archive();
      final doc = await pdfrx.PdfDocument.openData(pdfBytes);
      try {
        final pageCount = doc.pages.length;
        progress.value = (current: 0, total: pageCount);
        for (int i = 0; i < pageCount; i++) {
          final page = doc.pages[i];
          final rendered = await page.render(
            width: (page.width * 4).round(),
            height: (page.height * 4).round(),
            backgroundColor: const Color(0xFFFFFFFF),
          );
          if (rendered != null) {
            final uiImage = await rendered.createImage();
            final byteData =
                await uiImage.toByteData(format: ui.ImageByteFormat.png);
            if (byteData != null) {
              final pngBytes = byteData.buffer.asUint8List();
              final name = 'page_${(i + 1).toString().padLeft(3, '0')}.png';
              archive.addFile(ArchiveFile(name, pngBytes.length, pngBytes));
            }
          }
          progress.value = (current: i + 1, total: pageCount);
        }
      } finally {
        doc.dispose();
      }

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      final zipBytes =
          Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
      if (zipBytes.isEmpty) return null;

      final safeName = (suggestedName ?? state.note.title)
          .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      return await platformSaveBytes(
        zipBytes,
        suggestedName: '${safeName}_images',
        extension: 'zip',
        typeLabel: 'ZIP',
      );
    } catch (_) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      rethrow;
    } finally {
      progress.dispose();
    }
  }
}
