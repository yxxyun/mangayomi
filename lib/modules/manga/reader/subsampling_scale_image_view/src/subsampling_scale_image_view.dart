import 'dart:async';
import 'dart:ffi';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiori/shiori.dart';

import 'coordinate_transformer.dart';
import 'page_pan_forwarding.dart';
import 'row_pan.dart';
import 'ffi_image_decoder.dart';
import 'subsampling_image_painter.dart';
import 'subsampling_image_resolver.dart';
import 'subsampling_types.dart';
import 'tiling_engine.dart';
import '../../u_chap_data_preload.dart';
import '../../../../../services/jmcomic/jm_image_unscrambler.dart';

import 'package:mangayomi/utils/error_toast.dart';

import '../../utils/reader_motion.dart';

export 'subsampling_types.dart';

part 'subsampling_pan.dart';
part 'subsampling_tile_loading.dart';

// ─── Controller ───────────────────────────────────────────────────────────────

/// Controller for programmatic control of [SubsamplingScaleImageView].
class SubsamplingScaleImageViewController extends ChangeNotifier {
  _SubsamplingScaleImageViewState? _state;

  void _attach(_SubsamplingScaleImageViewState state) {
    _state = state;
  }

  /// Only [state]'s own detach counts: when a page moves to another slot,
  /// its replacement attaches before the old view is disposed, and the old
  /// view must not unhook it.
  void _detach(_SubsamplingScaleImageViewState state) {
    if (identical(_state, state)) _state = null;
  }

  // ── State Getters ──────────────────────────────────────────────────────────

  bool get isReady =>
      _state?._loadState == LoadState.completed &&
      (_state?._isInitialized ?? false);
  double get scale => _state?._scale ?? 1.0;
  double get minScale => _state?._getMinScale() ?? 1.0;
  ui.Offset get translation => _state?._vTranslate ?? ui.Offset.zero;
  int get sWidth => _state?._sWidth ?? 0;
  int get sHeight => _state?._sHeight ?? 0;

  ui.Size get imageSize {
    if (_state == null) return ui.Size.zero;
    return ui.Size(_state!._sWidth.toDouble(), _state!._sHeight.toDouble());
  }

  /// Current visible center (in source coordinates)
  ui.Offset? get center {
    final s = _state;
    if (s == null || !s._isInitialized) return null;
    final transformer = CoordinateTransformer(
      scale: s._scale,
      vTranslate: s._vTranslate,
      rotation: s.widget.rotation,
      sWidth: s._sWidth,
      sHeight: s._sHeight,
    );
    return transformer.vCoordToSCoord(
      ui.Offset(s._viewSize.width / 2, s._viewSize.height / 2),
    );
  }

  // ── Coordinate Conversion ────────────────────────────────────────────────

  /// Converts a view (screen) point to image source coordinates.
  ui.Offset? viewToSourceCoord(ui.Offset viewPoint) {
    final s = _state;
    if (s == null || !s._isInitialized) return null;
    return CoordinateTransformer(
      scale: s._scale,
      vTranslate: s._vTranslate,
      rotation: s.widget.rotation,
      sWidth: s._sWidth,
      sHeight: s._sHeight,
    ).vCoordToSCoord(viewPoint);
  }

  /// Converts an image source point to view (screen) coordinates.
  ui.Offset? sourceToViewCoord(ui.Offset sourcePoint) {
    final s = _state;
    if (s == null || !s._isInitialized) return null;
    return CoordinateTransformer(
      scale: s._scale,
      vTranslate: s._vTranslate,
      rotation: s.widget.rotation,
      sWidth: s._sWidth,
      sHeight: s._sHeight,
    ).sCoordToVCoord(sourcePoint);
  }

  /// Returns the visible rectangle of the source (in source coordinates).
  ui.Rect? visibleSourceRect() {
    final s = _state;
    if (s == null || !s._isInitialized) return null;
    final transformer = CoordinateTransformer(
      scale: s._scale,
      vTranslate: s._vTranslate,
      rotation: s.widget.rotation,
      sWidth: s._sWidth,
      sHeight: s._sHeight,
    );
    final topLeft = transformer.vCoordToSCoord(ui.Offset.zero);
    final bottomRight = transformer.vCoordToSCoord(
      ui.Offset(s._viewSize.width, s._viewSize.height),
    );
    return ui.Rect.fromPoints(topLeft, bottomRight);
  }

  // ── Commands ───────────────────────────────────────────────────────────────

  /// Resets scale and center to initial state.
  void resetScaleAndCenter() => _state?._reset();

  /// Sets scale and translation directly (without animation).
  void setScaleAndTranslation(double scale, ui.Offset translation) {
    _state?._setScaleAndTranslation(scale, translation);
  }

  /// Sets scale and centers the view on a source point (without animation).
  void setScaleAndCenter(double scale, ui.Offset sCenter) {
    _state?._setScaleAndCenter(scale, sCenter);
  }

  /// Animates to a scale and source center.
  void animateScaleAndCenter(
    double targetScale,
    ui.Offset sCenter, {
    Duration duration = ShioriMotion.enter,
  }) {
    _state?._animateScaleAndCenter(targetScale, sCenter, duration);
  }

  /// Animates to a scale and translation.
  void animateScaleAndTranslation(
    double targetScale,
    ui.Offset targetTranslate, {
    Duration duration = ShioriMotion.enter,
  }) {
    _state?._animateScaleAndTranslation(targetScale, targetTranslate, duration);
  }
}

// ─── Widget ───────────────────────────────────────────────────────────────────

class SubsamplingScaleImageView extends StatefulWidget {
  /// The image to display. Accepts any [ImageProvider]: [FileImage], [NetworkImage],
  /// [AssetImage], [MemoryImage], etc.
  final ImageProvider<Object> image;

  /// Optional pre-resolved local file path of the image.
  /// If provided, the widget will bypass the ImageProvider resolving pipeline
  /// and load directly from this path.
  final String? resolvedFilePath;

  /// Optional preload data for caching resolved file path.
  final UChapDataPreload? preloadData;

  /// Callback called on every loading state change.
  /// Returns a custom widget for [LoadState.loading] and [LoadState.failed] states,
  /// or null to use the default behavior.
  ///
  /// Example :
  /// ```dart
  /// loadStateChanged: (state) {
  ///   if (state.loadState == LoadState.failed) {
  ///     return GestureDetector(
  ///       onTap: state.reLoadImage,
  ///       child: const Icon(Symbols.error_rounded, fill: 1),
  ///     );
  ///   }
  ///   if (state.loadState == LoadState.loading) {
  ///     final progress = state.loadingProgress?.expectedTotalBytes != null
  ///       ? state.loadingProgress!.cumulativeBytesLoaded /
  ///         state.loadingProgress!.expectedTotalBytes!
  ///       : 0.0;
  ///     return CircularProgressIndicator(value: progress > 0 ? progress : null);
  ///   }
  ///   return null; // standard display
  /// }
  /// ```
  final Widget? Function(SubsamplingImageState state)? loadStateChanged;

  // ── Rotation and gestures ───────────────────────────────────────────────────────

  /// Image rotation: 0, 90, 180, or 270 degrees.
  final int rotation;
  final bool panEnabled;
  final bool zoomEnabled;
  final bool quickScaleEnabled;
  final bool showDebug;
  final bool isVisible;

  // ── Image processing ───────────────────────────────────────────────────────

  /// Automatically crops white/black/transparent borders.
  final bool cropBorders;
  final double parentScale;

  // ── Layout ──────────────────────────────────────────────────────────────

  /// How to fit the image into the view. Maps to [ScaleType] if provided.
  /// If null, [minimumScaleType] is used.
  final BoxFit? fit;

  /// Fit mode for the initial minimum scale (alternative to [fit]).
  final ScaleType minimumScaleType;

  /// Mode for limiting panning to the edges.
  final PanLimit panLimit;

  // ── Zoom limits ────────────────────────────────────────────────────────

  /// Maximum allowed scale. null = 8× minimum scale.
  final double? maxScale;

  /// Minimum scale (used only if [minimumScaleType] == [ScaleType.custom]).
  final double? minScale;

  // ── Double tap ────────────────────────────────────────────────────────────────

  /// Target double-tap scale. null = 2.5× minimum scale.
  final double? doubleTapZoomScale;
  final Duration doubleTapZoomDuration;

  // ── Visual rendering ─────────────────────────────────────────────────────────────

  /// If non-null, this color is blended with each pixel via [colorBlendMode].
  final Color? color;

  /// Blend mode for [color] with the image. Default: [BlendMode.srcIn].
  final BlendMode? colorBlendMode;

  /// Filtering quality when rendering. Default: [FilterQuality.medium].
  final FilterQuality filterQuality;

  // ── Controller and callbacks ────────────────────────────────────────────────

  final SubsamplingScaleImageViewController? controller;

  /// Optional. Allows coordinating image panning with page scrolling of the parent PageView.
  final PageController? pageController;

  /// Called when the image is ready to be displayed.
  final VoidCallback? onReady;

  /// Called when the image is successfully loaded, provides real dimensions of the image.
  final void Function(int width, int height)? onImageLoaded;

  /// Called when the scale changes.
  final ValueChanged<double>? onScaleChanged;

  /// Called when the visible center changes (source coordinates).
  final ValueChanged<ui.Offset>? onCenterChanged;

  /// Called in case of error loading the image.
  final ValueChanged<String>? onError;

  /// Called in case of error loading a tile.
  final ValueChanged<String>? onTileError;

  const SubsamplingScaleImageView({
    super.key,
    required this.image,
    this.resolvedFilePath,
    this.preloadData,
    this.loadStateChanged,
    this.rotation = 0,
    this.panEnabled = true,
    this.zoomEnabled = true,
    this.quickScaleEnabled = true,
    this.showDebug = false,
    this.cropBorders = false,
    this.parentScale = 1.0,
    this.isVisible = true,
    this.srcRect,
    this.fit,
    this.minimumScaleType = ScaleType.centerInside,
    this.panLimit = PanLimit.inside,
    this.maxScale,
    this.minScale,
    this.doubleTapZoomScale,
    this.doubleTapZoomDuration = ShioriMotion.enter,
    this.color,
    this.colorBlendMode,
    this.filterQuality = FilterQuality.medium,
    this.controller,
    this.pageController,
    this.onReady,
    this.onImageLoaded,
    this.onScaleChanged,
    this.onCenterChanged,
    this.onError,
    this.onTileError,
  });

  /// A source sub-region (srcRect) to display.
  /// If provided, the viewer will display only this sub-region and adapt all scales and translations.
  final Rect? srcRect;

  @override
  State<SubsamplingScaleImageView> createState() =>
      _SubsamplingScaleImageViewState();
}

// ─── State ────────────────────────────────────────────────────────────────────

class _SubsamplingScaleImageViewState extends State<SubsamplingScaleImageView>
    with SingleTickerProviderStateMixin {
  // Tiling
  late TilingEngine _tilingEngine;
  bool _isInitialized = false;
  bool _rebuildScheduled = false;
  /// Tile-loading helpers live in the tile-loading part (extension on this
  /// class); extensions are outside the State class, so protected setState
  /// is reached through this shim.
  void rebuildTiles() => setState(() {});
  /// Full-image RGBA bytes cache for the fallback tile path; owned by the
  /// class because extensions cannot declare instance fields.
  Uint8List? fallbackBytes;
  int _sWidth = 0;
  int _sHeight = 0;

  // View
  double _scale = 1.0;
  ui.Offset _vTranslate = ui.Offset.zero;
  ui.Size _viewSize = ui.Size.zero;

  // ImageProvider loading
  LoadState _loadState = LoadState.loading;
  ImageChunkEvent? _loadingProgress;
  String? _resolvedFilePath;
  ImageStream? _activeImageStream;
  ImageStreamListener? _activeImageStreamListener;
  /// Fallback ui.Image from ImageStream, used when the FFI decoder
  /// cannot decode the cached file format (e.g. WebP on Windows).
  ui.Image? _fallbackImage;

  // Gestures
  double _scaleStart = 1.0;
  ui.Offset _vTranslateStart = ui.Offset.zero;
  ui.Offset _focalPointStart = ui.Offset.zero;
  ui.Offset _lastGlobalFocalPoint = ui.Offset.zero;

  // Quick scale (1-finger zoom)
  bool _isQuickScaling = false;
  double _quickScaleLastY = 0;
  double _quickScaleLastDistance = -1;
  ui.Offset? _quickScaleSCenter;

  // Animation
  late AnimationController _animationController;
  Animation<double>? _scaleAnimation;
  Animation<ui.Offset>? _translateAnimation;

  // Previous state for callbacks
  double _lastNotifiedScale = 0;
  ui.Offset _lastNotifiedCenter = ui.Offset.zero;
  Timer? _resizeTimer;

  @override
  void initState() {
    super.initState();
    _tilingEngine = TilingEngine();
    _animationController = AnimationController(
      vsync: this,
      duration: ShioriMotion.enter,
    );
    _animationController.addListener(() {
      if (_scaleAnimation != null && _translateAnimation != null) {
        setState(() {
          _scale = _scaleAnimation!.value;
          _vTranslate = _translateAnimation!.value;
        });
        _notifyStateChanged();
        _refreshTiles(load: false);
      }
    });
    _animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _refreshTiles(load: true);
      }
    });
    widget.controller?._attach(this);

    // Starts loading after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadFromProvider();
    });
  }

  @override
  void dispose() {
    _resizeTimer?.cancel();
    _cancelImageStream();
    widget.controller?._detach(this);
    _animationController.dispose();
    _tilingEngine.dispose();
    _fallbackImage?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SubsamplingScaleImageView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }

    // Reloads if the provider or critical options change
    final imageChanged =
        widget.resolvedFilePath != oldWidget.resolvedFilePath ||
        (widget.resolvedFilePath == null && widget.image != oldWidget.image);
    final cropChanged = widget.cropBorders != oldWidget.cropBorders;
    final scaleTypeChanged =
        widget.minimumScaleType != oldWidget.minimumScaleType ||
        widget.fit != oldWidget.fit;

    if (imageChanged || cropChanged) {
      _isInitialized = false;
      _tilingEngine.dispose();
      _tilingEngine = TilingEngine();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadFromProvider();
      });
    } else if (scaleTypeChanged && _isInitialized) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _setupInitialViewState());
      });
    }

    final parentScaleChanged = widget.parentScale != oldWidget.parentScale;
    if (parentScaleChanged && _isInitialized) {
      _refreshTiles(load: true);
    }

    final visibilityChanged = widget.isVisible != oldWidget.isVisible;
    if (visibilityChanged) {
      if (!widget.isVisible) {
        // Cancel all pending decodes for this page
        for (final grid in _tilingEngine.tileMap.values) {
          for (final tile in grid) {
            if (tile.loading) {
              ffiImageDecoder.cancel(tile);
              tile.loading = false;
            }
          }
        }
      } else {
        // Trigger tile refresh when it becomes visible
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _refreshTiles(load: true);
          }
        });
      }
    }
  }

  void _loadTile(Tile tile) {
    if (_resolvedFilePath == null) return;
    tile.loading = true;

    // When the ImageStream path already decoded the image (e.g. WebP that the
    // FFI decoder can't handle, or JM scrambled images that were restored),
    // load tiles directly from the decoded [_fallbackImage].
    if (_fallbackImage != null) {
      tile.loading = false;
      _loadTileFromFallback(tile);
      return;
    }

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

    final params = DecodeParams(
      filePath: _resolvedFilePath!,
      left: fileRect.left.toInt(),
      top: fileRect.top.toInt(),
      right: fileRect.right.toInt(),
      bottom: fileRect.bottom.toInt(),
      sampleSize: tile.sampleSize,
      cropBorders: widget.cropBorders,
    );
    ffiImageDecoder.decodeRegionAsync(params, cancelToken: tile).then((result) {
      if (result == null) return;
      if (result.pointerAddress != null) {
        final int left = fileRect.left.toInt();
        final int top = fileRect.top.toInt();
        final int right = fileRect.right.toInt();
        final int bottom = fileRect.bottom.toInt();
        final int destWidth = (right - left) ~/ tile.sampleSize;
        final int destHeight = (bottom - top) ~/ tile.sampleSize;

        final pointer = Pointer<Uint8>.fromAddress(result.pointerAddress!);
        final bytes = pointer.asTypedList(destWidth * destHeight * 4);

        if (!mounted) {
          calloc.free(pointer);
          return;
        }

        try {
          ui.decodeImageFromPixels(
            bytes,
            destWidth,
            destHeight,
            ui.PixelFormat.rgba8888,
            (ui.Image img) {
              calloc.free(pointer);
              if (!mounted) {
                img.dispose();
                return;
              }
              tile.image = img;
              tile.loading = false;
              if (_loadState != LoadState.completed) {
                _loadState = LoadState.completed;
                _notifyStateChanged();
                widget.onReady?.call();
                widget.onImageLoaded?.call(_sWidth, _sHeight);
              }
              _scheduleBatchRebuild();
            },
          );
        } catch (e) {
          calloc.free(pointer);
          tile.loading = false;
          if (mounted) {
            setState(() {});
          }
        }
      } else if (_fallbackImage != null) {
        // FFI decoder failed. Use the fallback ImageStream image.
        tile.loading = false;
        _loadTileFromFallback(tile);
      } else {
        tile.loading = false;
        final msg = result.error ?? 'Unknown error';
        if (msg != 'Cancelled') {
          if (kDebugMode) {
            debugPrint('SubsamplingScaleImageView: Tile decoding failed: $msg');
          }
          widget.onTileError?.call(msg);
        }
      }
    });
  }
  // ── ImageProvider Resolution ──────────────────────────────────────────

  void _cancelImageStream() {
    if (_activeImageStream != null && _activeImageStreamListener != null) {
      _activeImageStream!.removeListener(_activeImageStreamListener!);
      _activeImageStream = null;
      _activeImageStreamListener = null;
    }
  }

  Future<void> _loadFromProvider({bool evictCache = false}) async {
    _cancelImageStream();

    // Early network URL detection: JM images are scrambled and MUST go through
    // the ImageStream path so they can be restored before tiling.
    String? networkUrl;
    String? cacheFolderName;
    try {
      final dynamic dynProvider = widget.image;
      networkUrl = dynProvider.url;
      cacheFolderName = dynProvider.imageCacheFolderName;
    } catch (_) {}
    final bool isJm = networkUrl?.contains('jmapiproxy') ?? false;

    if (mounted) {
      setState(() {
        _loadState = LoadState.loading;
        _loadingProgress = null;
        _isInitialized = false;
      });
    }

    if (evictCache) {
      final provider = widget.image;
      try {
        await provider.evict();
      } catch (_) {}
    }

    if (widget.resolvedFilePath != null) {
      _resolvedFilePath = widget.resolvedFilePath;
      if (!isJm && await _tryInitImage()) return;
      // JM images fall through to the ImageStream restore path.
    }

    final provider = widget.image;

    // 1-3. Fast paths (file / memory / cached network) live in the shared
    // resolver. JM URLs stay scrambled on disk and in every cache, so the
    // fast paths only apply to non-JM images; JM always takes the
    // ImageStream path and gets unscrambled before tiling.
    if (!isJm) {
      final (fastPath, fastUrl, fastFolder) =
          await tryResolveFastPathProvider(provider);
      networkUrl ??= fastUrl;
      cacheFolderName ??= fastFolder;
      if (fastPath != null) {
        _resolvedFilePath = fastPath;
        if (await _tryInitImage()) return;
        // The FFI decoder choked on the cached file (WebP on some
        // platforms); fall through to the ImageStream path, whose
        // fallback tiles from the decoded ui.Image instead.
      }
    }

    // 4. General path: resolution via ImageStream
    final completer = Completer<ui.Image>();

    final stream = provider.resolve(ImageConfiguration.empty);
    _activeImageStream = stream;

    final listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!completer.isCompleted) {
          completer.complete(info.image);
        }
      },
      onError: (Object e, StackTrace? st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st ?? StackTrace.empty);
        }
      },
      onChunk: (ImageChunkEvent chunk) {
        if (mounted) {
          setState(() => _loadingProgress = chunk);
        }
      },
    );

    _activeImageStreamListener = listener;
    stream.addListener(listener);

    try {
      final ui.Image loadedImage = await completer.future;
      // Restore JM scrambled images (horizontal strip reorder) before tiling.
      ui.Image displayImage = loadedImage;
      if (isJm) {
        final restored = await JmImageUnscrambler.restoreIfNeeded(
          loadedImage,
          networkUrl ?? '',
        );
        if (restored != null) {
          displayImage = restored;
        }
      }
      _fallbackImage = displayImage;
      fallbackBytes = null;
      _cancelImageStream();

      if (!mounted) return;

      // Initialise tile dimensions from the decoded ImageStream result.
      _sWidth = widget.srcRect != null
          ? widget.srcRect!.width.toInt()
          : displayImage.width;
      _sHeight = widget.srcRect != null
          ? widget.srcRect!.height.toInt()
          : displayImage.height;

      // Try the fast file-based init first (supports JPEG already cached).
      if (networkUrl != null && !isJm) {
        final cachedFile = await findCachedImageFile(
          networkUrl,
          cacheFolderName,
        );
        if (cachedFile != null) {
          _resolvedFilePath = cachedFile.path;
          if (await _tryInitImage()) return;
          // FFI decoder failed on cached WebP. Tile loading will fall
          // back to [_fallbackImage].
        }
      }

// Initialise the tile engine directly from ImageStream dimensions.
      // (FFI decoder cannot decode WebP on Windows, so skip the PNG-encode
      // path and use the Dart-decoded image directly.)
      if (mounted && _viewSize.width > 0 && _viewSize.height > 0) {
        _setupInitialViewState();
        if (mounted) setState(() => _loadState = LoadState.completed);
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('SubsamplingScaleImageView: Failed to load image: $e\n$st');
      }
      _cancelImageStream();
      if (mounted) {
        setState(() => _loadState = LoadState.failed);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onError?.call(e.toString());
        });
      }
    }
  }

  SubsamplingImageState _makeImageState() => SubsamplingImageState(
    loadState: _loadState,
    loadingProgress: _loadingProgress,
    reLoadCallback: () => _loadFromProvider(evictCache: true),
  );

  // ── Internal Controller ───────────────────────────────────────────────────────

  void _reset() {
    if (!mounted || !_isInitialized) return;
    setState(() => _setupInitialViewState());
    _refreshTiles(load: true);
  }

  void _setScaleAndTranslation(double scale, ui.Offset translation) {
    if (!mounted || !_isInitialized) return;
    setState(() {
      _scale = _clampScale(scale);
      _vTranslate = _clampTranslate(translation, _scale);
    });
    _notifyStateChanged();
    _refreshTiles(load: true);
  }

  void _setScaleAndCenter(double scale, ui.Offset sCenter) {
    if (!mounted || !_isInitialized) return;
    final clampedScale = _clampScale(scale);
    final targetTranslate = _translationForScaleAndCenter(
      clampedScale,
      sCenter,
    );
    setState(() {
      _scale = clampedScale;
      _vTranslate = targetTranslate;
    });
    _notifyStateChanged();
    _refreshTiles(load: true);
  }

  ui.Offset _translationForScaleAndCenter(
    double targetScale,
    ui.Offset sCenter,
  ) {
    final transformer = CoordinateTransformer(
      scale: targetScale,
      vTranslate: ui.Offset.zero,
      rotation: widget.rotation,
      sWidth: _sWidth,
      sHeight: _sHeight,
    );
    final vPoint = transformer.sCoordToVCoord(sCenter);
    return _clampTranslate(
      ui.Offset(
        _viewSize.width / 2 - vPoint.dx,
        _viewSize.height / 2 - vPoint.dy,
      ),
      targetScale,
    );
  }

  void _animateScaleAndCenter(
    double targetScale,
    ui.Offset sCenter,
    Duration duration,
  ) {
    if (!mounted || !_isInitialized) return;
    final clampedScale = _clampScale(targetScale);
    final targetTranslate = _translationForScaleAndCenter(
      clampedScale,
      sCenter,
    );
    _startAnimation(
      _scale,
      clampedScale,
      _vTranslate,
      targetTranslate,
      duration,
    );
  }

  void _animateScaleAndTranslation(
    double targetScale,
    ui.Offset targetTranslate,
    Duration duration,
  ) {
    if (!mounted || !_isInitialized) return;
    final clampedScale = _clampScale(targetScale);
    _startAnimation(
      _scale,
      clampedScale,
      _vTranslate,
      _clampTranslate(targetTranslate, clampedScale),
      duration,
    );
  }

  void _startAnimation(
    double fromScale,
    double toScale,
    ui.Offset fromTranslate,
    ui.Offset toTranslate,
    Duration duration, {
    Curve curve = Curves.easeOutCubic,
  }) {
    _scaleAnimation = Tween<double>(
      begin: fromScale,
      end: toScale,
    ).animate(CurvedAnimation(parent: _animationController, curve: curve));
    _translateAnimation = Tween<ui.Offset>(
      begin: fromTranslate,
      end: toTranslate,
    ).animate(CurvedAnimation(parent: _animationController, curve: curve));
    _animationController.duration = duration;
    _animationController.reset();
    _animationController.forward();
  }

  // ── State Callbacks ────────────────────────────────────────────────────────

  void _notifyStateChanged() {
    if (!mounted) return;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    widget.controller?.notifyListeners();
    if (widget.onScaleChanged != null && _scale != _lastNotifiedScale) {
      _lastNotifiedScale = _scale;
      widget.onScaleChanged!(_scale);
    }
    if (widget.onCenterChanged != null) {
      final transformer = CoordinateTransformer(
        scale: _scale,
        vTranslate: _vTranslate,
        rotation: widget.rotation,
        sWidth: _sWidth,
        sHeight: _sHeight,
      );
      final currentCenter = transformer.vCoordToSCoord(
        ui.Offset(_viewSize.width / 2, _viewSize.height / 2),
      );
      if (currentCenter != _lastNotifiedCenter) {
        _lastNotifiedCenter = currentCenter;
        widget.onCenterChanged!(currentCenter);
      }
    }
  }

  // ── Initialization ──────────────────────────────────────────────────────────

  /// Tries to initialize using the FFI decoder.
  /// Returns `true` on success, `false` if the file format is unsupported (e.g. WebP).
  Future<bool> _tryInitImage() async {
    final path = _resolvedFilePath;
    if (path == null) return false;
    try {
      final outSize = await ffiImageDecoder.getImageDimensionsAsync(
        path,
        cropBorders: widget.cropBorders,
      );
      if (outSize == null || outSize[0] == 0 || outSize[1] == 0) {
        return false;
      }
      _sWidth = widget.srcRect != null
          ? widget.srcRect!.width.toInt()
          : outSize[0];
      _sHeight = widget.srcRect != null
          ? widget.srcRect!.height.toInt()
          : outSize[1];
      if (mounted && _viewSize.width > 0 && _viewSize.height > 0) {
        _setupInitialViewState();
        if (mounted) setState(() => _loadState = LoadState.completed);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _initImage() async {
    var path = _resolvedFilePath;
    if (path == null) return;

    var outSize = await ffiImageDecoder.getImageDimensionsAsync(
      path,
      cropBorders: widget.cropBorders,
    );

    if (!mounted || _resolvedFilePath != path) return;

    if (outSize == null || outSize[0] == 0 || outSize[1] == 0) {
      try {
        // What the native decoder cannot read on this system, as a PNG
        // decoded by Flutter.
        final convertedPath =
            await convertLegacyIosAvifToPng(path) ??
            await convertLinuxJpegToPng(path);
        if (!mounted || _resolvedFilePath != path) return;
        if (convertedPath != null) {
          path = convertedPath;
          _resolvedFilePath = path;
          outSize = await ffiImageDecoder.getImageDimensionsAsync(
            path,
            cropBorders: widget.cropBorders,
          );
        }
      } catch (e, st) {
        recordError(e, stack: st, source: 'reader image conversion');
      }
    }

    if (!mounted || _resolvedFilePath != path) return;

    if (outSize == null || outSize[0] == 0 || outSize[1] == 0) {
      final msg = 'Failed to analyze image: $path';
      if (kDebugMode) {
        debugPrint('SubsamplingScaleImageView: $msg');
      }
      if (mounted) {
        setState(() => _loadState = LoadState.failed);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onError?.call(msg);
        });
      }
      return;
    }

    _sWidth = widget.srcRect != null
        ? widget.srcRect!.width.toInt()
        : outSize[0];
    _sHeight = widget.srcRect != null
        ? widget.srcRect!.height.toInt()
        : outSize[1];

    if (mounted && _viewSize.width > 0 && _viewSize.height > 0) {
      _setupInitialViewState();
      if (mounted) setState(() => _loadState = LoadState.completed);
    }
  }

  void _setupInitialViewState() {
    final transformer = CoordinateTransformer(
      scale: 1.0,
      vTranslate: ui.Offset.zero,
      rotation: widget.rotation,
      sWidth: _sWidth,
      sHeight: _sHeight,
    );

    final effWidth = transformer.effectiveSWidth.toDouble();
    final effHeight = transformer.effectiveSHeight.toDouble();

    _scale = _calcMinScaleForType(effWidth, effHeight);

    final double tx = (_viewSize.width - (effWidth * _scale)) / 2;
    final double ty = (_viewSize.height - (effHeight * _scale)) / 2;
    _vTranslate = ui.Offset(tx, ty);

    const int baseSampleSize = 1;

    _tilingEngine.initialiseTileMap(
      sWidth: _sWidth,
      sHeight: _sHeight,
      maxTileWidth: 4096.0,
      maxTileHeight: 4096.0,
      baseSampleSize: baseSampleSize,
      viewWidth: _viewSize.width,
      viewHeight: _viewSize.height,
    );

    _isInitialized = true;
    _refreshTiles(load: true);
  }

  // ── Scale and Type Calculations ────────────────────────────────────────────

  ScaleType get _effectiveScaleType =>
      resolveEffectiveScaleType(widget.fit, widget.minimumScaleType);

  double _calcMinScaleForType(double effWidth, double effHeight) =>
      calculateMinScaleForType(
        effWidth: effWidth,
        effHeight: effHeight,
        viewSize: _viewSize,
        effectiveScaleType: _effectiveScaleType,
        customMinScale: widget.minScale,
      );

  double _getMinScale() {
    final transformer = CoordinateTransformer(
      scale: 1.0,
      vTranslate: ui.Offset.zero,
      rotation: widget.rotation,
      sWidth: _sWidth,
      sHeight: _sHeight,
    );
    return _calcMinScaleForType(
      transformer.effectiveSWidth.toDouble(),
      transformer.effectiveSHeight.toDouble(),
    );
  }

  double _getMaxScale() => widget.maxScale ?? _getMinScale() * 8.0;

  double _clampScale(double scale) =>
      max(_getMinScale(), min(_getMaxScale(), scale));

  // ── Pan clamping ─────────────────────────────────────────────────────────────

  ui.Offset _clampTranslate(ui.Offset translate, double scale) =>
      clampPanTranslation(
        translate: translate,
        scale: scale,
        rotation: widget.rotation,
        sWidth: _sWidth,
        sHeight: _sHeight,
        viewSize: _viewSize,
        panLimit: widget.panLimit,
      );

  // ── Tile loading ─────────────────────────────────────────────────────────────

  void _refreshTiles({required bool load}) {
    if (!_isInitialized || _resolvedFilePath == null) return;

    final transformer = CoordinateTransformer(
      scale: _scale,
      vTranslate: _vTranslate,
      rotation: widget.rotation,
      sWidth: _sWidth,
      sHeight: _sHeight,
    );

    final effWidth = transformer.effectiveSWidth;
    final double reqWidth = effWidth * _scale * widget.parentScale;

    int targetSampleSize = 1;
    if (effWidth > reqWidth) {
      targetSampleSize = (effWidth / reqWidth).round();
      int power = 1;
      while (power * 2 < targetSampleSize) {
        power *= 2;
      }
      targetSampleSize = power;
    }
    targetSampleSize = min(targetSampleSize, _tilingEngine.fullImageSampleSize);

    _tilingEngine.refreshRequiredTiles(
      scale: _scale,
      vTranslate: _vTranslate,
      viewSize: _viewSize,
      rotation: widget.rotation,
      sWidth: _sWidth,
      sHeight: _sHeight,
      targetSampleSize: targetSampleSize,
      loadTileCallback: (tile) {
        if (load) _loadTile(tile);
      },
    );
  }

  // ── Gesture handlers ─────────────────────────────────────────────────────────

  void _handleScaleStart(ScaleStartDetails details) {
    if (_animationController.isAnimating) {
      _animationController.stop();
    }
    _scaleStart = _scale;
    _vTranslateStart = _vTranslate;
    _focalPointStart = details.localFocalPoint;
    _lastGlobalFocalPoint = details.focalPoint;
    _isQuickScaling = false;
    _quickScaleLastDistance = -1;
    _quickScaleSCenter = null;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (!_isInitialized) return;

    final ui.Offset currentGlobalFocal = details.focalPoint;
    final ui.Offset globalDelta = currentGlobalFocal - _lastGlobalFocalPoint;
    _lastGlobalFocalPoint = currentGlobalFocal;

    double newScale = _scale;
    ui.Offset newTranslate = _vTranslate;

    if (widget.zoomEnabled && details.scale != 1.0) {
      _isQuickScaling = false;
      newScale = _clampScale(_scaleStart * details.scale);
    } else if (widget.quickScaleEnabled && _isQuickScaling) {
      final double dy = details.localFocalPoint.dy;
      final double dist = (dy - _focalPointStart.dy).abs() * 2 + 20;

      if (_quickScaleLastDistance < 0) _quickScaleLastDistance = dist;
      final bool isUpwards = dy < _quickScaleLastY;
      _quickScaleLastY = dy;

      final double spanDiff =
          (1 - (dist / _quickScaleLastDistance)).abs() * 0.5;
      if (spanDiff > 0.03) {
        final double multiplier = isUpwards ? (1 + spanDiff) : (1 - spanDiff);
        newScale = _clampScale(_scale * multiplier);
        if (_quickScaleSCenter != null) {
          newTranslate = _translationForScaleAndCenter(
            newScale,
            _quickScaleSCenter!,
          );
        }
      }
      _quickScaleLastDistance = dist;
    }

    if (widget.panEnabled && !_isQuickScaling) {
      if (details.pointerCount == 1) {
        // 1-finger panning / page scrolling using global coordinates delta
        final proposedTranslate = _vTranslate + globalDelta;
        final clampedTranslate = _clampTranslate(proposedTranslate, newScale);

        if (widget.pageController != null &&
            widget.pageController!.hasClients &&
            _scale <= _getMinScale() * 1.01) {
          final pos = widget.pageController!.position;
          final double delta = pageScrollDeltaForPan(
            pos.axisDirection,
            proposedTranslate - clampedTranslate,
          );
          if (delta != 0) {
            pos.jumpTo(
              (pos.pixels + delta).clamp(
                pos.minScrollExtent,
                pos.maxScrollExtent,
              ),
            );
          }
        }
        newTranslate = clampedTranslate;
      } else if (details.pointerCount > 1) {
        // Multi-finger pinch-to-zoom using standard local focal anchor
        final ui.Offset focalPoint = details.localFocalPoint;
        final ui.Offset relativeFocal = focalPoint - _vTranslateStart;
        newTranslate = focalPoint - relativeFocal * (newScale / _scaleStart);
        newTranslate = _clampTranslate(newTranslate, newScale);
      }
    }

    setState(() {
      _scale = newScale;
      _vTranslate = newTranslate;
    });
    _notifyStateChanged();
    _refreshTiles(load: false);
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    if (widget.panEnabled && _isInitialized && !_isQuickScaling) {
      final velocity = details.velocity.pixelsPerSecond;
      if (velocity.distance > 400) {
        final targetTranslate = _clampTranslate(
          _vTranslate + velocity * ReaderMotion.flingTravel,
          _scale,
        );
        if ((targetTranslate - _vTranslate).distance > 10) {
          _startAnimation(
            _scale,
            _scale,
            _vTranslate,
            targetTranslate,
            ReaderMotion.flingDuration,
            curve: Curves.decelerate,
          );
        }
      }
    }
    _isQuickScaling = false;
    _refreshTiles(load: true);

    // Coordinate PageController snapping
    if (widget.pageController != null &&
        widget.pageController!.hasClients &&
        _scale <= _getMinScale() * 1.01) {
      final position = widget.pageController!.position;
      final double currentPageValue = widget.pageController!.page ?? 0.0;
      final int targetPage = settlePage(
        currentPageValue,
        position.axisDirection,
        details.velocity.pixelsPerSecond,
      );
      // Settled in the time the release speed takes, so the page carries on
      // at the finger's pace rather than speeding up or braking.
      final extent = position.viewportDimension;
      final duration = ReaderMotion.settle(
        distance: (targetPage - currentPageValue) * extent,
        extent: extent,
        velocity: pageScrollDeltaForPan(
          position.axisDirection,
          details.velocity.pixelsPerSecond,
        ),
      );
      if (duration == Duration.zero) return;
      widget.pageController!.animateToPage(
        targetPage,
        duration: duration,
        curve: ReaderMotion.quinticOut,
      );
    }
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    if (!_isInitialized) return;

    final double minScale = _getMinScale();
    final double dtScale = widget.doubleTapZoomScale ?? (minScale * 2.5);
    final double clampedDtScale = min(_getMaxScale(), dtScale);
    final double targetScale = (_scale > minScale * 1.5)
        ? minScale
        : clampedDtScale;

    if (widget.quickScaleEnabled) {
      _isQuickScaling = true;
      _quickScaleLastY = details.localPosition.dy;
      _quickScaleLastDistance = -1;
      final transformer = CoordinateTransformer(
        scale: _scale,
        vTranslate: _vTranslate,
        rotation: widget.rotation,
        sWidth: _sWidth,
        sHeight: _sHeight,
      );
      _quickScaleSCenter = transformer.vCoordToSCoord(details.localPosition);
    }

    final ui.Offset tapPosition = details.localPosition;
    final ui.Offset relativeTap = tapPosition - _vTranslate;
    final ui.Offset targetTranslate = _clampTranslate(
      tapPosition - relativeTap * (targetScale / _scale),
      targetScale,
    );

    _scaleAnimation = Tween<double>(begin: _scale, end: targetScale).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOutQuad,
      ),
    );
    _translateAnimation =
        Tween<ui.Offset>(begin: _vTranslate, end: targetTranslate).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOutQuad,
          ),
        );
    _animationController.duration = widget.doubleTapZoomDuration;
    _animationController.forward(from: 0.0);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double screenWidth =
            MediaQuery.maybeOf(context)?.size.width ?? 300.0;
        final double screenHeight =
            MediaQuery.maybeOf(context)?.size.height ?? 300.0;

        final double newHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : (_sHeight > 0 && _sWidth > 0 && constraints.maxWidth.isFinite)
            ? (constraints.maxWidth * _sHeight / _sWidth)
            : (constraints.minHeight > 0
                  ? constraints.minHeight
                  : screenHeight);

        final double newWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (_sHeight > 0 && _sWidth > 0 && newHeight.isFinite)
            ? (newHeight * _sWidth / _sHeight)
            : (constraints.minWidth > 0 ? constraints.minWidth : screenWidth);

        if (_viewSize.width != newWidth || _viewSize.height != newHeight) {
          final bool isFirstLayout = _viewSize == ui.Size.zero;
          _viewSize = ui.Size(newWidth, newHeight);
          if (isFirstLayout) {
            // No debounce for initial layout — start loading immediately
            if (_sWidth > 0 && _sHeight > 0) {
              _setupInitialViewState();
            } else if (_resolvedFilePath != null) {
              _tryInitImage().then((ok) {
                if (mounted && !ok) {
                  // FFI decoder failed (e.g. WebP). Reload via ImageProvider.
                  _loadFromProvider();
                }
              });
            }
          } else {
            _resizeTimer?.cancel();
            _resizeTimer = Timer(const Duration(milliseconds: 150), () {
              if (!mounted) return;
              if (_sWidth > 0 && _sHeight > 0) {
                _setupInitialViewState();
              } else if (_resolvedFilePath != null) {
                _initImage();
              }
            });
          }
        }

        // Displays custom state widget if image is not ready
        if (_loadState != LoadState.completed || !_isInitialized) {
          final stateWidget = widget.loadStateChanged?.call(_makeImageState());
          if (stateWidget != null) return stateWidget;

          // Default UI
          return switch (_loadState) {
            LoadState.loading => Center(
              child: _loadingProgress?.expectedTotalBytes != null
                  ? CircularProgressIndicator(
                      value:
                          _loadingProgress!.cumulativeBytesLoaded /
                          _loadingProgress!.expectedTotalBytes!,
                    )
                  : const CircularProgressIndicator(),
            ),
            LoadState.failed => Center(
              child: GestureDetector(
                onTap: () => _loadFromProvider(evictCache: true),
                child: Icon(
                  Symbols.broken_image_rounded,
                  color: context.shiori.color.fgMuted,
                  size: 48,
                ),
              ),
            ),
            LoadState.completed => const SizedBox.shrink(),
          };
        }

        return GestureDetector(
          onScaleStart: widget.zoomEnabled || widget.panEnabled
              ? _handleScaleStart
              : null,
          onScaleUpdate: widget.zoomEnabled || widget.panEnabled
              ? _handleScaleUpdate
              : null,
          onScaleEnd: widget.zoomEnabled || widget.panEnabled
              ? _handleScaleEnd
              : null,
          onDoubleTapDown: widget.zoomEnabled ? _handleDoubleTapDown : null,
          child: ClipRect(
            child: SubsamplingImageRenderWidget(
              tilingEngine: _tilingEngine,
              scale: _scale,
              vTranslate: _vTranslate,
              rotation: widget.rotation,
              sWidth: _sWidth,
              sHeight: _sHeight,
              showDebug: widget.showDebug,
              color: widget.color,
              colorBlendMode: widget.colorBlendMode,
              filterQuality: widget.filterQuality,
              preferredSize: _viewSize,
            ),
          ),
        );
      },
    );
  }
}
