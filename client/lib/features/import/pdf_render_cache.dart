// PdfRenderCache — renders PDF pages to PNG files on disk at 3 fixed scales
// (200%, 400%, 800%) so BackgroundImageLayer can show cached images instead
// of re-rendering on every frame (which causes flickering).
//
// Cache files are stored at:
//   <applicationDocumentsDirectory>/notee-pdf-cache/{assetId}_p{pageNo}_s{scalePct}.png
//
// Architecture: a single FIFO queue is drained by [_maxConcurrent] parallel
// workers. The pick order is determined by membership of the page in two
// hint sets, giving 3 effective priority bands:
//   P0 — pages currently visible in the open notebook
//   P1 — other pages of the open notebook
//   P2 — anything else (other notes, prefetch from imports/sync)
// The next-job picker scans P0 first, then P1, then takes whatever is at
// the head of the queue, so workers never idle while there's work to do.
//
// The thread count is mutable at runtime via [setMaxConcurrent].

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors, Size;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfRenderJobView {
  PdfRenderJobView({
    required this.assetId,
    required this.pageNo,
    required this.scalePct,
  });
  final String assetId;
  final int pageNo;
  final int scalePct;
}

class _RenderJob {
  _RenderJob({
    required this.pdfFile,
    required this.assetId,
    required this.pageNo,
    required this.pageSize,
    required this.scalePct,
  });

  final File pdfFile;
  final String assetId;
  final int pageNo;
  final Size pageSize;
  final int scalePct;

  String get key => '${assetId}_p${pageNo}_s$scalePct';
  String get pageKey => '$assetId#$pageNo';

  PdfRenderJobView toView() =>
      PdfRenderJobView(assetId: assetId, pageNo: pageNo, scalePct: scalePct);
}

class PdfRenderCache {
  PdfRenderCache._();
  static final PdfRenderCache instance = PdfRenderCache._();

  static const allScales = [200, 400, 800];

  // Default thread count — overridden by user settings on app start.
  int _maxConcurrent = 2;
  int get maxConcurrent => _maxConcurrent;
  void setMaxConcurrent(int n) {
    _maxConcurrent = n.clamp(1, 8);
    _pump();
    _changes.add(null);
  }

  final _controller =
      StreamController<({String assetId, int pageNo, int scalePct})>.broadcast();
  Stream<({String assetId, int pageNo, int scalePct})> get onCached =>
      _controller.stream;

  // Fires whenever the queue / in-progress / settings change. Used by the
  // queue-viewer modal to refresh.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changes.stream;

  final List<_RenderJob> _queue = [];
  final Set<String> _inProgress = {};
  int _running = 0;

  // Priority hints (page-level membership; do not include scale).
  Set<String> _visibleKeys = {};
  Set<String> _currentNoteKeys = {};

  /// The canvas calls this when the visible page changes. Pass an empty
  /// set when no notebook is open. Page keys = "$assetId#$pageNo".
  void setVisiblePages(Set<({String assetId, int pageNo})> pages) {
    final keys = pages.map((p) => '${p.assetId}#${p.pageNo}').toSet();
    if (_setEq(keys, _visibleKeys)) return;
    _visibleKeys = keys;
    _changes.add(null);
  }

  /// The canvas calls this when a notebook opens (full page list) or closes
  /// (empty set).
  void setCurrentNotePages(Set<({String assetId, int pageNo})> pages) {
    final keys = pages.map((p) => '${p.assetId}#${p.pageNo}').toSet();
    if (_setEq(keys, _currentNoteKeys)) return;
    _currentNoteKeys = keys;
    _changes.add(null);
  }

  bool _setEq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  // ── Cache directory ────────────────────────────────────────────────────────

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'notee-pdf-cache'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _fileName(String assetId, int pageNo, int scalePct) =>
      '${assetId}_p${pageNo}_s$scalePct.png';

  Future<File?> getCached(String assetId, int pageNo, int scalePct) async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, _fileName(assetId, pageNo, scalePct)));
    return await f.exists() ? f : null;
  }

  // ── Scale selection ────────────────────────────────────────────────────────

  static int scaleForZoom(double zoom) {
    if (zoom < 2.0) return 200;
    if (zoom < 4.0) return 400;
    return 800;
  }

  // ── Queue management ──────────────────────────────────────────────────────

  /// Enqueues render jobs for a single page at the given scales. Priority is
  /// derived from current visible/current-note membership at pick time, so
  /// callers don't need to specify it. Duplicate jobs (same key already
  /// queued or in-flight) are silently ignored.
  void enqueue(
    File pdfFile,
    String assetId,
    int pageNo,
    Size pageSize,
    List<int> scalePcts,
  ) {
    var added = false;
    for (final scale in scalePcts) {
      final key = '${assetId}_p${pageNo}_s$scale';
      if (_inProgress.contains(key)) continue;
      if (_queue.any((j) => j.key == key)) continue;
      _queue.add(_RenderJob(
        pdfFile: pdfFile,
        assetId: assetId,
        pageNo: pageNo,
        pageSize: pageSize,
        scalePct: scale,
      ));
      added = true;
    }
    if (added) _changes.add(null);
    _pump();
  }

  /// Pre-warms 200% renders for an entire note in the background. Called
  /// when a notebook opens. Visible pages will subsequently be picked first
  /// via the visibility hints.
  void prewarmAllPages(
    List<({File file, String assetId, int pageNo, Size pageSize})> pages,
  ) {
    for (final page in pages) {
      enqueue(page.file, page.assetId, page.pageNo, page.pageSize, [200]);
    }
  }

  // ── Workers ───────────────────────────────────────────────────────────────

  void _pump() {
    while (_running < _maxConcurrent && _queue.isNotEmpty) {
      final idx = _pickNextIndex();
      if (idx < 0) break;
      final job = _queue.removeAt(idx);
      _inProgress.add(job.key);
      _running++;
      _changes.add(null);
      _renderOne(job).whenComplete(() {
        _inProgress.remove(job.key);
        _running--;
        _changes.add(null);
        _pump();
      });
    }
  }

  int _pickNextIndex() {
    if (_queue.isEmpty) return -1;
    // P0 — currently visible.
    for (var i = 0; i < _queue.length; i++) {
      if (_visibleKeys.contains(_queue[i].pageKey)) return i;
    }
    // P1 — open notebook.
    for (var i = 0; i < _queue.length; i++) {
      if (_currentNoteKeys.contains(_queue[i].pageKey)) return i;
    }
    // P2 — anything (FIFO).
    return 0;
  }

  Future<void> _renderOne(_RenderJob job) async {
    final dir = await _cacheDir();
    final outFile = File(p.join(dir.path, _fileName(job.assetId, job.pageNo, job.scalePct)));
    if (await outFile.exists()) return;

    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(job.pdfFile.path);
      if (job.pageNo < 1 || job.pageNo > doc.pages.length) return;
      final page = doc.pages[job.pageNo - 1];

      const maxDim = 8192;
      final w = math.min(
        (job.pageSize.width * job.scalePct / 100).round(),
        maxDim,
      );
      final h = math.min(
        (job.pageSize.height * job.scalePct / 100).round(),
        maxDim,
      );
      if (w <= 0 || h <= 0) return;

      final pdfImage = await page.render(
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: Colors.white,
      );
      if (pdfImage == null) return;

      final uiImage = await pdfImage.createImage();
      pdfImage.dispose();

      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      uiImage.dispose();

      if (byteData == null) return;

      await outFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

      _controller.add((
        assetId: job.assetId,
        pageNo: job.pageNo,
        scalePct: job.scalePct,
      ));
    } catch (_) {
      // Skip on error; next job continues.
    } finally {
      await doc?.dispose();
    }
  }

  // ── Snapshot for the queue-viewer modal ───────────────────────────────────

  ({
    List<PdfRenderJobView> p0,
    List<PdfRenderJobView> p1,
    List<PdfRenderJobView> p2,
    List<PdfRenderJobView> running,
    int maxConcurrent,
  }) snapshot() {
    final p0 = <PdfRenderJobView>[];
    final p1 = <PdfRenderJobView>[];
    final p2 = <PdfRenderJobView>[];
    for (final j in _queue) {
      if (_visibleKeys.contains(j.pageKey)) {
        p0.add(j.toView());
      } else if (_currentNoteKeys.contains(j.pageKey)) {
        p1.add(j.toView());
      } else {
        p2.add(j.toView());
      }
    }
    final running = _queue
        .where((j) => _inProgress.contains(j.key))
        .map((j) => j.toView())
        .toList();
    // _queue does not contain in-flight items; emit a synthetic list from
    // the in-progress key set instead.
    final runningFromKeys = _inProgress.map((k) {
      // key is ${assetId}_p${pageNo}_s${scale} — parse it.
      // assetIds are SHA-256 hex (no underscores) so this is safe.
      final parts = k.split('_');
      // [assetId, p<n>, s<n>]
      final assetId = parts[0];
      final pageNo = int.tryParse(parts[1].substring(1)) ?? 0;
      final scalePct = int.tryParse(parts[2].substring(1)) ?? 0;
      return PdfRenderJobView(
          assetId: assetId, pageNo: pageNo, scalePct: scalePct);
    }).toList();
    running.addAll(runningFromKeys);
    return (
      p0: p0,
      p1: p1,
      p2: p2,
      running: runningFromKeys,
      maxConcurrent: _maxConcurrent,
    );
  }
}
