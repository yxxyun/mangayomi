import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

/// JMComic (禁漫天堂) image unscrambling.
///
/// JM serves images split into horizontal strips (full-width slices) that are
/// stacked in reversed vertical order. The number of strips is derived from the
/// chapter id + image filename via MD5. This class restores the original image.
///
/// Reference: JMComic-Crawler-Python `JmImageTool.get_num()` /
/// `decode_and_save()` and JMComic-qt `SegmentationPicture()`.
class JmImageUnscrambler {
  /// Fallback scramble_id when the chapter's real value is not fetched.
  static const int _scrambleDefault = 220980;
  static const int _scramble268850 = 268850;
  static const int _scramble421926 = 421926;

  /// Number of horizontal strips this image was split into.
  /// Returns 0 when the image is NOT scrambled.
  static int getNum(
    int chapterId,
    String filename, {
    int scrambleId = _scrambleDefault,
  }) {
    if (chapterId < scrambleId) return 0;
    if (chapterId < _scramble268850) return 10;
    final int x = chapterId < _scramble421926 ? 10 : 8;
    final String s = '$chapterId$filename';
    final String md5Hex = md5.convert(utf8.encode(s)).toString();
    final String last = md5Hex[md5Hex.length - 1];
    final int n = last.codeUnitAt(0) % x;
    return n * 2 + 2;
  }

  /// Extracts `(chapterId, filename)` from a JM CDN image URL such as
  /// `https://cdn-msp.jmapiproxy1.cc/media/photos/1453521/00001.webp`.
  static (int, String)? parseUrl(String url) {
    final m = RegExp(
      r'/media/photos/(\d+)/([^/.?]+)',
    ).firstMatch(url);
    if (m == null) return null;
    final chapterId = int.tryParse(m.group(1)!);
    if (chapterId == null) return null;
    return (chapterId, m.group(2)!);
  }

  /// Restores the image if the URL is a scrambled JM image.
  /// Returns the restored image, or null when no restoration is needed.
  static Future<ui.Image?> restoreIfNeeded(ui.Image img, String url) async {
    final parsed = parseUrl(url);
    if (parsed == null) return null;
    final (chapterId, filename) = parsed;
    final num = getNum(chapterId, filename);
    if (num == 0) return null;
    return restore(img, num);
  }

  /// Splits [img] into [num] horizontal strips and pastes them in reversed
  /// order, restoring the original image.
  static Future<ui.Image> restore(ui.Image img, int num) async {
    final int w = img.width;
    final int h = img.height;
    final ByteData? byteData =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return img;
    final Uint8List src = byteData.buffer.asUint8List();
    final Uint8List dst = Uint8List(w * h * 4);

    final int base = h ~/ num;
    final int over = h % num;

    for (int i = 0; i < num; i++) {
      int move = base;
      final int srcY = h - base * (i + 1) - over;
      int dstY = base * i;
      if (i == 0) {
        move += over;
      } else {
        dstY += over;
      }

      for (int y = 0; y < move; y++) {
        final int sr = srcY + y;
        final int dr = dstY + y;
        if (sr < 0 || sr >= h || dr < 0 || dr >= h) continue;
        final int si = sr * w * 4;
        final int di = dr * w * 4;
        dst.setRange(di, di + w * 4, src, si);
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      dst,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
