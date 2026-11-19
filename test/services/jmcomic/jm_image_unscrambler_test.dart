import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/jmcomic/jm_image_unscrambler.dart';

/// The strip count a JM page is cut into, and the round trip that puts it back.
///
/// These are the numbers the reference implementation (JMComic-Crawler
/// `JmImageTool.get_num`) produces; the reader depends on them being right,
/// because reversing the wrong number of strips leaves a page that looks like
/// it was shredded rather than restored.
void main() {
  group('strip count', () {
    test('no scramble below the first threshold', () {
      expect(JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 0), 0);
      expect(JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 220979), 0);
    });

    test('a fixed ten strips between the first and second threshold', () {
      expect(JmImageUnscrambler.getNum(1491637, '00001'), 10);
      expect(JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 220980), 10);
      expect(JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 268849), 10);
    });

    test('the id in the url is not a threshold, only an md5 input', () {
      // A photo id far above every threshold still yields the default's ten
      // strips: comparing it against the thresholds is what broke this.
      expect(JmImageUnscrambler.getNum(1491637, '00001'), 10);
      expect(JmImageUnscrambler.getNum(5000000, '00001'), 10);
    });

    test('above the second threshold the count is derived from the md5', () {
      final int num = JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 300000);
      expect(num >= 2 && num <= 20 && num.isEven, isTrue);
      final int num8 = JmImageUnscrambler.getNum(9999999, '00001', scrambleId: 421926);
      expect(num8 >= 2 && num8 <= 16 && num8.isEven, isTrue);
    });
  });

  group('url parsing', () {
    test('reads the photo id and file name', () {
      final parsed = JmImageUnscrambler.parseUrl(
        'https://cdn-msp.jmapiproxy1.cc/media/photos/1491637/00001.webp',
      );
      expect(parsed, isNotNull);
      expect(parsed!.$1, 1491637);
      expect(parsed.$2, '00001');
    });

    test('ignores anything that is not a photo url', () {
      expect(
        JmImageUnscrambler.parseUrl(
          'https://cdn-msp.jmapiproxy1.cc/media/albums/1490238_3x4.jpg',
        ),
        isNull,
      );
    });
  });

  group('deciding whether a page needs restoring', () {
    const url =
        'https://cdn-msp.jmapiproxy1.cc/media/photos/1491637/00001.webp';

    test('leaves a page that was never cut up alone', () async {
      final image = await _page(width: 64, height: 200, scrambledInto: 0);
      final restored = await JmImageUnscrambler.restoreIfNeeded(image, url);
      expect(restored, isNull);
    });

    test('restores a page cut into ten strips', () async {
      final image = await _page(width: 64, height: 200, scrambledInto: 10);
      final restored = await JmImageUnscrambler.restoreIfNeeded(image, url);
      expect(restored, isNotNull);
      expect(restored!.height, 200);
    });

    test('ignores an image that is not a jm photo', () async {
      final image = await _page(width: 64, height: 200, scrambledInto: 10);
      final restored = await JmImageUnscrambler.restoreIfNeeded(
        image,
        'https://cdn-msp.jmapiproxy1.cc/media/albums/1490238_3x4.jpg',
      );
      expect(restored, isNull);
    });
  });

  test('restoring a scrambled page gives the original back', () async {
    const int width = 40;
    const int height = 200;
    const int num = 10;
    final int strip = height ~/ num;

    // A page whose every row has its own colour, so a row that ends up in the
    // wrong place is visible as a mismatch.
    final pixels = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int i = (y * width + x) * 4;
        pixels[i] = y;
        pixels[i + 1] = x;
        pixels[i + 2] = (y * 7 + x * 3) % 256;
        pixels[i + 3] = 255;
      }
    }

    // JM ships the strips bottom to top.
    final scrambled = Uint8List(width * height * 4);
    for (int i = 0; i < num; i++) {
      final int srcY = strip * i;
      final int dstY = strip * (num - 1 - i);
      scrambled.setRange(
        dstY * width * 4,
        (dstY + strip) * width * 4,
        pixels,
        srcY * width * 4,
      );
    }

    final image = await _imageFrom(scrambled, width, height);
    final restored = await JmImageUnscrambler.restore(image, num);
    final bytes = await restored.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    expect(restored.width, width);
    expect(restored.height, height);
    expect(bytes!.buffer.asUint8List(), equals(pixels));
  });
}

/// A page whose rows carry a slowly varying pattern, so neighbouring rows look
/// alike and a wrongly joined strip shows up as a hard edge. When
/// [scrambledInto] is above zero the strips are reordered the way JM ships
/// them.
Future<ui.Image> _page({
  required int width,
  required int height,
  required int scrambledInto,
}) async {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final int i = (y * width + x) * 4;
      // Smooth down the page, patterned across it.
      pixels[i] = (y * 255 ~/ height);
      pixels[i + 1] = ((x * 255 ~/ width) + (y * 3)) % 256;
      pixels[i + 2] = (y * 255 ~/ height + x) % 256;
      pixels[i + 3] = 255;
    }
  }
  if (scrambledInto <= 1) return _imageFrom(pixels, width, height);

  final int strip = height ~/ scrambledInto;
  final scrambled = Uint8List(width * height * 4);
  for (var i = 0; i < scrambledInto; i++) {
    final int srcY = strip * i;
    final int dstY = strip * (scrambledInto - 1 - i);
    scrambled.setRange(
      dstY * width * 4,
      (dstY + strip) * width * 4,
      pixels,
      srcY * width * 4,
    );
  }
  return _imageFrom(scrambled, width, height);
}

Future<ui.Image> _imageFrom(Uint8List pixels, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
