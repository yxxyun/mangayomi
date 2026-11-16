part of 'subsampling_scale_image_view.dart';

// Tile loading helpers split out of the State class for the 1400-line guard:
// batch-rebuild coalescing and the pixel-crop fallback used when the FFI
// decoder cannot handle a cached file (WebP on some platforms) or when the
// image was restored through the ImageStream (JM descrambling).
//
// Wrapped in an extension on the State class so the methods keep the same
// semantics; setState is reached through a private shim (setState is only
// protected inside the State class itself, and extensions are outside it).

extension _SubsamplingTileLoading on _SubsamplingScaleImageViewState {
    // ── Batch Rebuild ──────────────────────────────────────────────────────────

    /// Coalesces multiple tile-completion setState calls into a single rebuild
    /// per microtask frame. Prevents cascading rebuilds when several tiles
    /// finish decoding within the same event loop iteration.
    void _scheduleBatchRebuild() {
      if (!_rebuildScheduled) {
        _rebuildScheduled = true;
        Future.microtask(() {
          if (!mounted) return;
          _rebuildScheduled = false;
          rebuildTiles();
          _refreshTiles(load: true);
        });
      }
    }

    /// Loads a tile region from [_fallbackImage] when the FFI decoder
    /// cannot handle the cached file format (e.g. WebP).
    Future<void> _loadTileFromFallback(Tile tile) async {
      if (_fallbackImage == null) return;
      final transformer = CoordinateTransformer(
        scale: _scale,
        vTranslate: _vTranslate,
        rotation: widget.rotation,
        sWidth: _sWidth,
        sHeight: _sHeight,
      );
      var fileRect = transformer.fileSRect(tile.sRect);
      if (widget.srcRect != null) {
        fileRect = fileRect.translate(widget.srcRect!.left, widget.srcRect!.top);
      }

      final int left = fileRect.left.toInt().clamp(0, _sWidth);
      final int top = fileRect.top.toInt().clamp(0, _sHeight);
      final int r = fileRect.right.toInt().clamp(0, _sWidth);
      final int b = fileRect.bottom.toInt().clamp(0, _sHeight);
      final int tileW = (r - left) ~/ tile.sampleSize;
      final int tileH = (b - top) ~/ tile.sampleSize;
      if (tileW <= 0 || tileH <= 0) return;

      try {
        // Cache the full-image RGBA bytes so each tile doesn't re-read the
        // whole image from the GPU.
        fallbackBytes ??= await _fallbackImage!.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ).then((d) => d?.buffer.asUint8List());
        if (fallbackBytes == null) return;
        final Uint8List fullPixels = fallbackBytes!;
        final int sw = _fallbackImage!.width;
        final Uint8List region = Uint8List(tileW * tileH * 4);
        for (int y = 0; y < tileH; y++) {
          final int sy = (top + y * tile.sampleSize).clamp(0, _sHeight - 1);
          final int di = y * tileW * 4;
          for (int x = 0; x < tileW; x++) {
            final int sx = (left + x * tile.sampleSize).clamp(0, sw - 1);
            final int sip = (sy * sw + sx) * 4;
            final int dip = di + x * 4;
            region[dip] = fullPixels[sip];
            region[dip + 1] = fullPixels[sip + 1];
            region[dip + 2] = fullPixels[sip + 2];
            region[dip + 3] = fullPixels[sip + 3];
          }
        }

        if (!mounted) return;
        ui.decodeImageFromPixels(
          region,
          tileW,
          tileH,
          ui.PixelFormat.rgba8888,
          (ui.Image img) {
            if (!mounted) {
              img.dispose();
              return;
            }
            // Mark-needs-build is enough: the tile fields are read during
            // build, and the state callback fires on its own.
            tile.image = img;
            tile.loading = false;
            if (_loadState != LoadState.completed) {
              _loadState = LoadState.completed;
              _notifyStateChanged();
              widget.onReady?.call();
              widget.onImageLoaded?.call(_sWidth, _sHeight);
            }
            rebuildTiles();
            _refreshTiles(load: true);
          },
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('_loadTileFromFallback FAIL: $e');
        }
        tile.loading = false;
      }
    }
}
