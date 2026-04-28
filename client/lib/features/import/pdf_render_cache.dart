// PdfRenderCache — pre-renders PDF pages to PNG files on disk at 4 fixed
// scales (25%, 200%, 400%, 800%) so BackgroundImageLayer can show cached
// images instead of re-rendering on every frame (which causes flickering).
//
// Cache files are stored at:
//   <applicationDocumentsDirectory>/notee-pdf-cache/{assetId}_p{pageNo}_s{scalePct}.png
//
// Jobs are processed one at a time to avoid overwhelming the device.
// After each successful write a broadcast event is emitted on [onCached].

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors, Size;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// A single render job.
class _RenderJob {
  _RenderJob({
    required this.pdfFile,
    required this.assetId,
    required this.pageNo,
    required this.pageSize,
    required this.scalePcts,
  });

  final File pdfFile;
  final String assetId;
  final int pageNo;
  final Size pageSize;
  final List<int> scalePcts;
}

class PdfRenderCache {
  PdfRenderCache._();
  static final PdfRenderCache instance = PdfRenderCache._();

  static const allScales = [25, 200, 400, 800];

  final _controller =
      StreamController<({String assetId, int pageNo, int scalePct})>.broadcast();

  /// Fires after each successful PNG cache write.
  Stream<({String assetId, int pageNo, int scalePct})> get onCached =>
      _controller.stream;

  final _queue = <_RenderJob>[];
  bool _running = false;

  // ── Cache directory ────────────────────────────────────────────────────────

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'notee-pdf-cache'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _fileName(String assetId, int pageNo, int scalePct) =>
      '${assetId}_p${pageNo}_s$scalePct.png';

  /// Returns the cached PNG [File] if it already exists on disk, otherwise null.
  Future<File?> getCached(String assetId, int pageNo, int scalePct) async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, _fileName(assetId, pageNo, scalePct)));
    return await f.exists() ? f : null;
  }

  // ── Scale selection ────────────────────────────────────────────────────────

  /// Returns the display-target scale percentage for a given [zoom] level.
  /// 25% is never a target — it is used only as a fast-loading placeholder.
  static int scaleForZoom(double zoom) {
    if (zoom < 2.0) return 200;
    if (zoom < 4.0) return 400;
    return 800;
  }

  // ── Queue management ──────────────────────────────────────────────────────

  /// Enqueues a render job for [scalePcts] on the given PDF page.
  ///
  /// If [front] is true the job is inserted at the front of the queue
  /// (high-priority, e.g. currently visible page at a new zoom).
  /// Duplicate scale entries (same assetId + pageNo + scale) that are already
  /// queued are filtered out before inserting.
  void enqueue(
    File pdfFile,
    String assetId,
    int pageNo,
    Size pageSize,
    List<int> scalePcts, {
    bool front = false,
  }) {
    // Remove scales that are already queued or being processed.
    final pending = <int>[];
    for (final s in scalePcts) {
      final alreadyQueued = _queue.any(
        (j) => j.assetId == assetId && j.pageNo == pageNo && j.scalePcts.contains(s),
      );
      if (!alreadyQueued) pending.add(s);
    }
    if (pending.isEmpty) return;

    final job = _RenderJob(
      pdfFile: pdfFile,
      assetId: assetId,
      pageNo: pageNo,
      pageSize: pageSize,
      scalePcts: pending,
    );

    if (front) {
      _queue.insert(0, job);
    } else {
      _queue.add(job);
    }

    _pump();
  }

  /// Ensures 25% thumbnails exist for a list of pages. Pages whose 25% cache
  /// file already exists on disk are silently skipped (async check inside
  /// [_pump] / render). Used on notebook open and after import.
  void ensureThumbnails(
    List<({File file, String assetId, int pageNo, Size pageSize})> pages,
  ) {
    for (final page in pages) {
      enqueue(page.file, page.assetId, page.pageNo, page.pageSize, [25]);
    }
  }

  // ── Worker ────────────────────────────────────────────────────────────────

  void _pump() {
    if (_running || _queue.isEmpty) return;
    _running = true;
    _processNext();
  }

  Future<void> _processNext() async {
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      await _renderJob(job);
    }
    _running = false;
  }

  Future<void> _renderJob(_RenderJob job) async {
    // Filter scales that are already on disk so we never overwrite valid cache.
    final dir = await _cacheDir();
    final scalesToRender = <int>[];
    for (final s in job.scalePcts) {
      final f = File(p.join(dir.path, _fileName(job.assetId, job.pageNo, s)));
      if (!await f.exists()) scalesToRender.add(s);
    }
    if (scalesToRender.isEmpty) return;

    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(job.pdfFile.path);
      final page = doc.pages[job.pageNo - 1];

      for (final scalePct in scalesToRender) {
        const maxDim = 8192;
        final w = math.min(
          (job.pageSize.width * scalePct / 100).round(),
          maxDim,
        );
        final h = math.min(
          (job.pageSize.height * scalePct / 100).round(),
          maxDim,
        );
        if (w <= 0 || h <= 0) continue;

        try {
          final pdfImage = await page.render(
            fullWidth: w.toDouble(),
            fullHeight: h.toDouble(),
            backgroundColor: Colors.white,
          );
          if (pdfImage == null) continue;

          final uiImage = await pdfImage.createImage();
          pdfImage.dispose();

          final byteData =
              await uiImage.toByteData(format: ui.ImageByteFormat.png);
          uiImage.dispose();

          if (byteData == null) continue;

          final outFile =
              File(p.join(dir.path, _fileName(job.assetId, job.pageNo, scalePct)));
          await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

          _controller.add((
            assetId: job.assetId,
            pageNo: job.pageNo,
            scalePct: scalePct,
          ));
        } catch (_) {
          // Skip this scale on error; the next scale or next job continues.
        }
      }
    } catch (_) {
      // If the document can't be opened, skip the whole job silently.
    } finally {
      await doc?.dispose();
    }
  }
}
