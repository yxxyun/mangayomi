import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_chapter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/page.dart';

void _jmDiag(String msg) {
  try {
    final f = File('${Directory.systemTemp.path}/mangayomi_jmcomic.log');
    f.writeAsStringSync('${DateTime.now()}: $msg\n', mode: FileMode.append);
  } catch (_) {}
}

/// Built-in 禁漫天堂 (jmcomic) source — 18+ manga.
///
/// Fetches manga data from the jmcomic API with AES-ECB encrypted responses.
/// All requests use time-based auth tokens that must match the decryption key.
class JmcomicService {
  // Multiple fallback API domains.
  // These are the mobile API endpoints, not the web site domain.
  // Mobile API proxy/CDN domains (NOT the website).
  // These are the correct endpoints for the encrypted mobile API.
  static const List<String> fallbackUrls = [
    'https://www.cdnhjk.net',
    'https://www.cdngwc.cc',
    'https://www.cdngwc.net',
    'https://www.cdngwc.club',
    'https://www.cdnutc.me',
  ];

  // CDN image base URLs (cover & page images).
  static const List<String> cdnUrls = [
    'https://cdn-msp.jmapiproxy1.cc',
    'https://cdn-msp.jmapiproxy3.cc',
    'https://cdn-msp.jmapinodeudzn.net',
    'https://cdn-msp.jmdanjonproxy.xyz',
    'https://cdn-msp2.jmapiproxy1.cc',
    'https://cdn-msp2.jmapiproxy3.cc',
    'https://cdn-msp2.jmapinodeudzn.net',
    'https://cdn-msp3.jmapinodeudzn.net',
    'https://cdn-msp3.jmapiproxy1.cc',
    'https://cdn-msp3.jmapiproxy3.cc',
  ];

  // Auth secret for standard API calls (getHeader in reference implementations).
  static const _jmAuthKey = '18comicAPP';
  // Decryption secret for AES-ECB encrypted response data.
  // Used as: MD5("$time$_jmSecret") → hex → UTF-8 key bytes → AES-256.
  static const _jmSecret = '185Hcomic3PAPP7R';
  static const _jmVersion = '1.7.2';

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro Build/TQ1A.230305.002; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/114.0.5735.196 Safari/537.36';

  String _baseUrl;

  JmcomicService({String? baseUrl}) : _baseUrl = baseUrl ?? fallbackUrls[0];

  void dispose() {}

  void setBaseUrl(String url) => _baseUrl = url;

  // ── Auth ──────────────────────────────────────────────────────────

  /// Generate time-based auth headers.
  ///
  /// Token is MD5("$time$_jmAuthKey") as hex string.
  /// The `time` must match between request auth and response decryption.
  Map<String, String> _authHeaders(int time, {bool post = false}) {
    final token = md5.convert(utf8.encode('$time$_jmAuthKey')).toString();
    return {
      'token': token,
      'tokenparam': '$time,$_jmVersion',
      'user-agent': _userAgent,
      'accept-encoding': 'gzip',
      if (post) 'content-type': 'application/x-www-form-urlencoded',
    };
  }

  // ── AES-ECB decryption ────────────────────────────────────────────

  /// Decrypt a base64-encoded AES-ECB payload.
  ///
  /// Encryption key: MD5("$time$_jmSecret").toString() → hex string → UTF-8
  /// bytes (32 bytes = AES-256). PKCS7 padding is used.
  /// Trailing garbage bytes after the last `}` or `]` are stripped.
  String _decryptData(String base64Data, int time) {
    final md5Key = md5.convert(utf8.encode('$time$_jmSecret'));
    final hexKey = md5Key.toString(); // 32 hex chars
    final key = enc.Key(utf8.encode(hexKey)); // 32 bytes → AES-256
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));

    final decrypted = encrypter.decrypt(enc.Encrypted.fromBase64(base64Data));

    // Strip trailing garbage characters after the last JSON delimiter.
    int i = decrypted.length - 1;
    while (i >= 0) {
      if (decrypted[i] == '}' || decrypted[i] == ']') break;
      i--;
    }
    return decrypted.substring(0, i + 1);
  }

  // ── HTTP ──────────────────────────────────────────────────────────

  /// Execute an authenticated GET request and return the decrypted JSON.
  /// Iterates through fallbackUrls on failure.
  /// Uses dart:io HttpClient directly to avoid Content-Type parsing issues
  /// in http.Client() when servers send invalid headers like
  /// "application/json; charset=utf-8;" (trailing semicolon).
  Future<dynamic> _get(String path) async {
    final urlsToTry = <String>[_baseUrl, ...fallbackUrls.where((u) => u != _baseUrl)];
    dynamic lastError;

    for (final base in urlsToTry) {
      try {
        final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final url = '$base$path';
        final uri = Uri.parse(url);

        final request = await HttpClient().getUrl(uri);
        final headers = _authHeaders(time);
        headers.forEach((k, v) => request.headers.set(k, v));
        final httpResponse = await request.close().timeout(const Duration(seconds: 15));

        if (httpResponse.statusCode != 200) {
          lastError = HttpException('jmcomic ${httpResponse.statusCode}', uri: uri);
          continue;
        }

        final bodyStr = await httpResponse.transform(utf8.decoder).join();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;

        if (body['code'] is int && body['code'] != 200) {
          lastError = Exception('jmcomic code=${body['code']}');
          continue;
        }

        final data = body['data'] as String?;
        if (data == null || data.isEmpty) {
          lastError = Exception('jmcomic empty data from $base');
          continue;
        }

        final decrypted = _decryptData(data, time);
        final parsed = jsonDecode(decrypted);
        _jmDiag('_get OK $base$path, decryptedType=${parsed.runtimeType}, keys=${parsed is Map ? parsed.keys.join(",") : "N/A"}');
        return parsed;
      } catch (e) {
        _jmDiag('_get FAIL $path on $base: $e');
        lastError = e;
        // Continue to next fallback URL.
      }
    }

    // All domains failed.
    _jmDiag('_get ALL FAILED: all $urlsToTry failed, last=$lastError');
    throw Exception('jmcomic unreachable: $lastError');
  }

  // ── Comic list parser ─────────────────────────────────────────────

  /// Parse a list of comic items from the API into the common map format.
  List<Map<String, String>> _parseComicList(List<dynamic> items) {
    return items.map<Map<String, String>>((comic) {
      final id = comic['id'].toString();
      return {
        'name': (comic['name'] ?? '未知').toString(),
        'imageUrl': _getCoverUrl(id),
        'link': id,
      };
    }).toList();
  }

  // ── Image URL helpers ─────────────────────────────────────────────

  /// Cover image URL from CDN.
  String _getCoverUrl(String id) => '${cdnUrls[0]}/media/albums/${id}_3x4.jpg';

  /// Page image URL from CDN.
  String _getPageUrl(String imageName, String chapterId) =>
      '${cdnUrls[0]}/media/photos/$chapterId/$imageName';

  // ── Source API methods ────────────────────────────────────────────

  /// Get manga detail and chapter list.
  Future<MManga?> getDetail(String albumId) async {
    try {
      final json = await _get('/album?comicName=&id=$albumId');

      final authorList = (json['author'] as List?)?.cast<String>() ?? ['未知'];
      final chapters = <MChapter>[];
      final seriesList = json['series'] as List? ?? [];
      for (final s in seriesList) {
        final chapId = s['id'].toString();
        final rawName = (s['name'] as String?)?.trim() ?? '';
        chapters.add(MChapter(
          name: rawName.isNotEmpty ? rawName : '第${s['sort']}話',
          url: chapId,
          scanlator: authorList.isNotEmpty ? authorList.first : '未知',
        ));
      }

      final tags = (json['tags'] as List?)?.cast<String>() ?? [];

      return MManga(
        name: json['name'] ?? '未知',
        imageUrl: _getCoverUrl(albumId),
        description: json['description'] ?? '',
        author: authorList.isNotEmpty ? authorList.first : '',
        genre: tags,
        link: albumId,
        chapters: chapters,
        status: Status.unknown,
      );
    } catch (e) {
      return null;
    }
  }

  /// Popular manga (homepage promote section).
  Future<List<Map<String, String>>> getPopular() async {
    try {
      final sections = await _get('/promote?&page=0') as List<dynamic>;
      if (sections.isEmpty) return [];
      // First promote section content.
      final first = sections[0] as Map<String, dynamic>;
      final items = first['content'] as List? ?? [];
      return _parseComicList(items);
    } catch (e) {
      return [];
    }
  }

  /// Latest updated manga.
  Future<List<Map<String, String>>> getLatestUpdates(int page) async {
    try {
      final json = await _get('/latest?&page=$page');
      final items = json as List? ?? [];
      return _parseComicList(items);
    } catch (e) {
      return [];
    }
  }

  /// Search manga by keyword.
  Future<List<Map<String, String>>> search(String query, int page) async {
    try {
      final encoded = Uri.encodeComponent(query).replaceAll('%20', '+');
      final json =
          await _get('/search?&search_query=$encoded&o=mr&page=$page');
      final content = json['content'] as List? ?? [];
      return _parseComicList(content);
    } catch (e) {
      return [];
    }
  }

  /// Get page image URLs for a chapter.
  Future<List<PageUrl>> getPageList(String chapterId) async {
    try {
      final json = await _get('/chapter?&id=$chapterId');
      final images = json['images'] as List? ?? [];
      _jmDiag('getPageList chapter=$chapterId, images=${images.length}');
      if (images.isEmpty) {
        _jmDiag('getPageList chapter=$chapterId, json keys=${json.keys.join(",")}');
      }
      final pageUrls = <PageUrl>[];
      for (var i = 0; i < images.length; i++) {
        final url = _getPageUrl(images[i].toString(), chapterId);
        if (i < 3) {
          _jmDiag('getPageList page${i}Url=$url');
        }
        pageUrls.add(PageUrl(
          url,
          headers: {
            'Referer': 'https://jmcomic1.me/',
            'User-Agent': _userAgent,
          },
        ));
      }
      return pageUrls;
    } catch (e) {
      _jmDiag('getPageList chapter=$chapterId FAILED: $e');
      return [];
    }
  }

  /// Category filter options.
  static List<dynamic> getFilterList() {
    return [
      SelectFilter(
        'categories',
        '分類',
        0,
        [
          SelectFilterOption('全部', 'all', 'SelectOption'),
          SelectFilterOption('同人', 'doujin', 'SelectOption'),
          SelectFilterOption('單行本', 'single', 'SelectOption'),
          SelectFilterOption('短篇', 'short', 'SelectOption'),
          SelectFilterOption('韓漫', 'hanman', 'SelectOption'),
          SelectFilterOption('美漫', 'meiman', 'SelectOption'),
          SelectFilterOption('同人cosplay', 'doujin_cosplay', 'SelectOption'),
          SelectFilterOption('3D', '3D', 'SelectOption'),
          SelectFilterOption('其他', 'another', 'SelectOption'),
        ],
        'SelectFilter',
      ),
    ];
  }

  /// Category-filtered manga list.
  Future<List<Map<String, String>>> getCategoryList(
      String category, int page) async {
    try {
      final json = await _get(
        '/categories/filter?&o=mr&c=${Uri.encodeComponent(category)}&page=$page',
      );
      final content = json['content'] as List? ?? [];
      return _parseComicList(content);
    } catch (e) {
      return [];
    }
  }
}
