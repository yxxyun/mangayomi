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
  ///
  /// [aid] is the photo id from the image URL. [scrambleId] is the album's
  /// scramble_id; the mirrors this app talks to do not return it, so it stays
  /// at the default, which the reference implementation maps to a fixed 10
  /// strips. The id in the URL is only an input to the md5, never a threshold:
  /// comparing it instead reported two strips for images cut into ten, and the
  /// "restored" page came out shredded.
  static int getNum(
    int aid,
    String filename, {
    int scrambleId = _scrambleDefault,
  }) {
    if (scrambleId < _scrambleDefault) return 0;
    if (scrambleId < _scramble268850) return 10;
    final int x = scrambleId < _scramble421926 ? 10 : 8;
    final String s = '$aid$filename';
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

  /// Restores the image if it actually needs restoring.
  ///
  /// The strip count normally comes from the album's scramble_id, but the
  /// mirrors this app talks to do not return one, and the images they serve
  /// are not always cut up at all. Guessing either way corrupts a page that
  /// was already fine, so the decision is made from the picture:
  ///
  /// Reversing strips changes nothing about the inside of a strip. Only the
  /// num-1 junctions between them change. If the page is scrambled, those
  /// junctions currently join unrelated rows and are sharp; after reversing
  /// they join the rows that belong together and are smooth. If the page was
  /// never scrambled, the opposite holds. So the arrangement with the smoother
  /// junctions wins, and it only counts as a restoration when it also wins by
  /// a clear margin.
  static Future<ui.Image?> restoreIfNeeded(ui.Image img, String url) async {
    if (parseUrl(url) == null) return null;

    final int w = img.width;
    final int h = img.height;
    if (h < 40 || w < 4) return null;

    final ByteData? byteData =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final Uint8List rgba = byteData.buffer.asUint8List();

    int? bestNum;
    double bestCost = 0;
    double baseline = 0;

    for (var num = 2; num <= 20; num += 2) {
      final int strip = h ~/ num;
      if (strip < 2) continue;
      // Where the page is cut right now, and where it would be cut after
      // reversing: both are the num-1 boundaries between strips, so the two
      // means are comparable.
      final double rawCost = _stripCost(rgba, w, h, num, reverse: false);
      final double fixedCost = _stripCost(rgba, w, h, num, reverse: true);
      if (bestNum == null || fixedCost < bestCost) {
        bestNum = num;
        bestCost = fixedCost;
        baseline = rawCost;
      }
    }

    if (bestNum == null) return null;
    // Only when reversing clearly smooths the page; a few percent either way
    // means the page was already whole.
    if (bestCost >= baseline * 0.8) return null;
    return restore(img, bestNum);
  }

  /// Mean difference across the strip boundaries a page would have with [num]
  /// strips, taken on the page as it is ([reverse] false) or after the strips
  /// are put back in order ([reverse] true).
  ///
  /// If the page is scrambled, the boundaries as they are join unrelated rows
  /// and are sharp, while the repaired ones join the rows that belong together
  /// and are smooth; if it was never scrambled, the reverse holds.
  static double _stripCost(
    Uint8List rgba,
    int width,
    int height,
    int num, {
    required bool reverse,
  }) {
    final int strip = height ~/ num;
    var sum = 0.0;
    var count = 0;
    for (var i = 1; i < num; i++) {
      // Rows meeting at this boundary: the last row of one strip and the first
      // of the next, in whichever order the page currently has them.
      final int lowerBlock = reverse ? num - i : i;
      final int upperBlock = lowerBlock - 1;
      final int upperRow = reverse
          ? (height - strip * (upperBlock + 1)) + strip - 1
          : upperBlock * strip + strip - 1;
      final int lowerRow = reverse
          ? height - strip * lowerBlock
          : lowerBlock * strip;
      if (upperRow < 0 || lowerRow < 0 || lowerRow >= height) continue;
      sum += _rowDiff(rgba, width, upperRow, lowerRow);
      count++;
    }
    return count == 0 ? 0 : sum / count;
  }

  /// How different two rows are, sampling across the width.
  static double _rowDiff(Uint8List rgba, int width, int rowA, int rowB) {
    final int a = rowA * width * 4;
    final int b = rowB * width * 4;
    var sum = 0.0;
    for (var x = 0; x < width; x += 4) {
      final int ia = a + x * 4;
      final int ib = b + x * 4;
      sum += (rgba[ia] - rgba[ib]).abs() +
          (rgba[ia + 1] - rgba[ib + 1]).abs() +
          (rgba[ia + 2] - rgba[ib + 2]).abs();
    }
    return sum;
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
