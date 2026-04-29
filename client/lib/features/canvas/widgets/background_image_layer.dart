// Renders an imported image or PDF page as the page background. Stacks
// above the white-paper layer but below the inked layers.
//
// PDF pages are served from PdfRenderCache (pre-rendered PNG files on disk)
// at one of three fixed scales: 200 %, 400 %, 800 %. If the target scale is
// not cached yet, the best already-cached lower scale is shown until the
// target arrives. The mass low-res (25 %) placeholder pre-pass was removed —
// each visible page enqueues its target scale at the front of the queue and
// the 2 worker threads drain it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../domain/page_spec.dart';
import '../../import/asset_service.dart';
import '../../import/pdf_render_cache.dart';

class BackgroundImageLayer extends StatefulWidget {
  const BackgroundImageLayer({
    super.key,
    required this.background,
    required this.size,
    this.zoom = 1.0,
  });

  final PageBackground background;
  final Size size;
  final double zoom;

  @override
  State<BackgroundImageLayer> createState() => _BackgroundImageLayerState();
}

class _BackgroundImageLayerState extends State<BackgroundImageLayer> {
  // For image backgrounds.
  File? _imageFile;

  // For PDF backgrounds.
  File? _pdfFile;
  File? _displayFile;
  int? _displayScale;

  StreamSubscription<({String assetId, int pageNo, int scalePct})>?
      _cacheSub;

  @override
  void initState() {
    super.initState();
    _resolveAsset();
    _subscribeCacheEvents();
  }

  @override
  void didUpdateWidget(covariant BackgroundImageLayer old) {
    super.didUpdateWidget(old);
    if (old.background != widget.background) {
      // Background changed entirely — reset all state and re-resolve.
      _imageFile = null;
      _pdfFile = null;
      _displayFile = null;
      _displayScale = null;
      _resolveAsset();
    } else if (widget.background is PdfBackground &&
        old.zoom != widget.zoom) {
      // Same PDF page but zoom changed — check if we need a better scale.
      _requestDisplay();
    }
  }

  @override
  void dispose() {
    _cacheSub?.cancel();
    super.dispose();
  }

  // ── Asset resolution ────────────────────────────────────────────────────

  Future<void> _resolveAsset() async {
    final bg = widget.background;
    final id = switch (bg) {
      ImageBackground(:final assetId) => assetId,
      PdfBackground(:final assetId) => assetId,
      _ => null,
    };
    if (id == null) return;

    final f = await AssetService().fileFor(id);
    if (!mounted) return;

    if (bg is ImageBackground) {
      setState(() => _imageFile = f);
    } else if (bg is PdfBackground && f != null) {
      _pdfFile = f;
      await _requestDisplay();
    }
  }

  // ── Cache subscription ──────────────────────────────────────────────────

  void _subscribeCacheEvents() {
    _cacheSub = PdfRenderCache.instance.onCached.listen((event) {
      if (!mounted) return;
      final bg = widget.background;
      if (bg is! PdfBackground) return;
      if (event.assetId != bg.assetId || event.pageNo != bg.pageNo) return;

      // Any newly-cached scale for our page is worth re-evaluating: it may
      // be the exact target, or a usable higher-res scale.
      final currentScale = _displayScale;
      final isBetter =
          currentScale == null || event.scalePct > currentScale;
      final targetScale = PdfRenderCache.scaleForZoom(widget.zoom);
      final isTarget = event.scalePct == targetScale;

      if (isTarget || isBetter) {
        _requestDisplay();
      }
    });
  }

  // ── Display selection ───────────────────────────────────────────────────

  /// Picks the lowest already-cached scale that is ≥ target. Any cached
  /// equal-or-higher scale is acceptable as the displayed background — no
  /// need to wait for the exact target. Falls back to a lower-scale
  /// placeholder + front-priority enqueue when nothing satisfies.
  Future<void> _requestDisplay() async {
    final bg = widget.background;
    if (bg is! PdfBackground) return;
    final pdfFile = _pdfFile;
    if (pdfFile == null) return;

    final targetScale = PdfRenderCache.scaleForZoom(widget.zoom);

    // Walk all scales sorted ascending; pick the first one ≥ target that's
    // already on disk. (allScales is [200, 400, 800].)
    final eligible = PdfRenderCache.allScales.where((s) => s >= targetScale).toList()
      ..sort();
    for (final s in eligible) {
      final f = await PdfRenderCache.instance.getCached(
          bg.assetId, bg.pageNo, s);
      if (f != null) {
        if (!mounted) return;
        setState(() {
          _displayFile = f;
          _displayScale = s;
        });
        return;
      }
    }

    // Nothing ≥ target cached. Use the highest cached lower scale as a
    // placeholder (better than blank) while we render the target.
    if (_displayFile == null) {
      final fallbacks = PdfRenderCache.allScales.where((s) => s < targetScale).toList()
        ..sort((a, b) => b.compareTo(a)); // highest first
      for (final s in fallbacks) {
        final f = await PdfRenderCache.instance.getCached(
            bg.assetId, bg.pageNo, s);
        if (f != null) {
          if (!mounted) return;
          setState(() {
            _displayFile = f;
            _displayScale = s;
          });
          break;
        }
      }
    }

    // Priority is derived from the cache's visible/current-note hints, so
    // a plain enqueue is sufficient — visible pages are picked first.
    PdfRenderCache.instance.enqueue(
        pdfFile, bg.assetId, bg.pageNo, widget.size, [targetScale]);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bg = widget.background;

    if (bg is ImageBackground) {
      if (_imageFile == null) return const SizedBox.shrink();
      return SizedBox(
        width: widget.size.width,
        height: widget.size.height,
        child: Image.file(
          _imageFile!,
          fit: BoxFit.fill,
          gaplessPlayback: true,
        ),
      );
    }

    if (bg is PdfBackground) {
      if (_displayFile == null) return const SizedBox.shrink();
      return SizedBox(
        width: widget.size.width,
        height: widget.size.height,
        child: Image.file(
          _displayFile!,
          fit: BoxFit.fill,
          gaplessPlayback: true,
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
