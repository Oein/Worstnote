// PDF importer: pick a PDF file, split it into 20-page chunk assets, and
// create one PageSpec per page pointing to its chunk. Loading a small chunk
// (~9 MB) instead of the full 180 MB document eliminates the disk bottleneck
// that caused 1–3 s initial load times.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;
import 'package:pdfrx/pdfrx.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../domain/page_spec.dart';
import 'asset_service.dart';
import 'pdf_render_cache.dart';

const _kChunkSize = 20;

class ImportedPdf {
  ImportedPdf({required this.title, required this.pages});
  final String title;
  final List<PageSpec> pages;
}

class PdfImporter {
  PdfImporter({AssetService? service}) : _service = service ?? AssetService();
  final AssetService _service;

  /// Opens a file picker, splits the PDF into [_kChunkSize]-page chunks,
  /// stores each chunk as an asset, and returns an [ImportedPdf] with per-page
  /// [PageSpec]s. Returns null on cancel.
  ///
  /// [onProgress] is called after each page with (completedCount, totalCount).
  Future<ImportedPdf?> pickAndImport({
    void Function(int current, int total)? onProgress,
  }) async {
    const group = XTypeGroup(label: 'PDF', extensions: ['pdf']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return null;

    final title = file.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final bytes = await file.readAsBytes();

    // Split into chunks in a background isolate so the UI stays responsive.
    final chunkBytesList = await compute(_splitIntoChunks, (bytes, _kChunkSize));
    if (chunkBytesList.isEmpty) return null;

    // Store each chunk via AssetService.
    final chunkIds = <String>[];
    for (final chunkBytes in chunkBytesList) {
      final ref = await _service.putBytes(chunkBytes, mime: 'application/pdf');
      chunkIds.add(ref.id);
    }

    // Use pdfrx to read per-page dimensions (width/height in points).
    final doc = await PdfDocument.openData(bytes);
    final pages = <PageSpec>[];
    // Capture page sizes while the document is still open.
    final pageSizes = <Size>[];
    try {
      final total = doc.pages.length;
      for (int i = 0; i < total; i++) {
        final page = doc.pages[i];
        pageSizes.add(Size(page.width, page.height));
        final chunkIndex = i ~/ _kChunkSize;
        final localPageNo = i % _kChunkSize + 1; // 1-indexed within chunk
        pages.add(PageSpec(
          widthPt: page.width,
          heightPt: page.height,
          kind: PaperKind.pdfImported,
          background: PageBackground.pdf(
            assetId: chunkIds[chunkIndex],
            pageNo: localPageNo,
          ),
        ));
        onProgress?.call(i + 1, total);
      }
    } finally {
      doc.dispose();
    }

    if (pages.isEmpty) return null;

    // Queue render of all 4 scales for each imported page (background task).
    for (int i = 0; i < pages.length; i++) {
      final bg = pages[i].background as PdfBackground;
      final file = await _service.fileFor(bg.assetId);
      if (file != null) {
        PdfRenderCache.instance.enqueue(
          file,
          bg.assetId,
          bg.pageNo,
          pageSizes[i],
          PdfRenderCache.allScales,
        );
      }
    }

    return ImportedPdf(title: title, pages: pages);
  }
}

/// Top-level function executed in a background isolate.
/// Splits [bytes] into ceil(pageCount / chunkSize) chunks using syncfusion,
/// discarding pages outside each chunk's range by removing them from the page
/// tree and forcing a full cross-reference rewrite (incrementalUpdate = false).
List<Uint8List> _splitIntoChunks((Uint8List bytes, int chunkSize) args) {
  final (bytes, chunkSize) = args;

  // Count pages cheaply with a fresh document.
  final countDoc = sf.PdfDocument(inputBytes: bytes);
  final totalPages = countDoc.pages.count;
  countDoc.dispose();

  if (totalPages == 0) return [];

  final chunkCount = (totalPages / chunkSize).ceil();
  final result = <Uint8List>[];

  for (int c = 0; c < chunkCount; c++) {
    final start = c * chunkSize;
    final end = (start + chunkSize).clamp(0, totalPages);

    final doc = sf.PdfDocument(inputBytes: bytes);
    // Force full rewrite so removed-page objects are not included in output.
    doc.fileStructure.incrementalUpdate = false;

    // Remove pages after end first (high→low to avoid index shifting).
    for (int i = totalPages - 1; i >= end; i--) {
      doc.pages.removeAt(i);
    }
    // Then remove pages before start (still high→low).
    for (int i = start - 1; i >= 0; i--) {
      doc.pages.removeAt(i);
    }

    result.add(Uint8List.fromList(doc.saveSync()));
    doc.dispose();
  }

  return result;
}
