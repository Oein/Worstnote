// Renders an imported image or PDF page as the page background. Stacks
// above the white-paper layer but below the inked layers.
//
// PDF pages are served from PdfRenderCache (pre-rendered PNG files on disk)
// at one of four fixed scales: 25 %, 200 %, 400 %, 800 %. If the ideal
// scale is not cached yet, the best available lower-res file is shown while
// the target scale is rendered in the background. This eliminates the
// blank-flash that the previous PdfPageView / in-memory render approach
// caused on every frame.

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
      // be the exact target, or a usable intermediate (e.g. 200% while
      // target is 800%) that beats the current 25% placeholder.
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

  /// Selects the best available cached file and enqueues whatever is needed.
  ///
  /// Loading sequence (first time, nothing cached):
  ///   1. enqueue [25]  → fast placeholder
  ///   2. onCached(25)  → calls _requestDisplay again → shows 25%, enqueues targetScale
  ///   3. onCached(200) → calls _requestDisplay again → shows 200%
  Future<void> _requestDisplay() async {
    final bg = widget.background;
    if (bg is! PdfBackground) return;
    final pdfFile = _pdfFile;
    if (pdfFile == null) return;

    final targetScale = PdfRenderCache.scaleForZoom(widget.zoom); // min 200

    // Best case: target is already cached → show it.
    final targetFile = await PdfRenderCache.instance.getCached(
        bg.assetId, bg.pageNo, targetScale);
    if (targetFile != null) {
      if (!mounted) return;
      setState(() { _displayFile = targetFile; _displayScale = targetScale; });
      return;
    }

    // Target not cached yet. Check for 25% placeholder.
    final thumbFile = await PdfRenderCache.instance.getCached(
        bg.assetId, bg.pageNo, 25);

    if (thumbFile != null) {
      // Show 25% while the target renders in the background.
      if (!mounted) return;
      if (_displayFile == null) {
        setState(() { _displayFile = thumbFile; _displayScale = 25; });
      }
      PdfRenderCache.instance.enqueue(
          pdfFile, bg.assetId, bg.pageNo, widget.size, [targetScale],
          front: true);
    } else {
      // Nothing cached yet — render 25% first (fast), then target follows
      // automatically when onCached fires and calls _requestDisplay again.
      PdfRenderCache.instance.enqueue(
          pdfFile, bg.assetId, bg.pageNo, widget.size, [25],
          front: true);
    }
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
