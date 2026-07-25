import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:http/http.dart' as http;
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_chapter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/page.dart';

/// Built-in 禁漫天堂 (jmcomic) source — 18+ manga.
///
/// Fetches manga data from the jmcomic API with AES-ECB encrypted responses.
/// All requests use time-based auth tokens that must match the decryption key.
class JmcomicService {
  // Multiple fallback API domains.
  static const List<String> fallbackUrls = [
    'https://www.jmeadpoolcdn.one',
    'https://www.jmeadpoolcdn.life',
    'https://www.jmapiproxyxxx.one',
    'https://www.jmfreedomproxy.xyz',
  ];

  // CDN image base URLs (cover & page images).
  static const List<String> cdnUrls = [
    'https://cdn-msp.jmapiproxy3.cc',
    'https://cdn-msp3.jmapiproxy3.cc',
    'https://cdn-msp2.jmapiproxy1.cc',
    'https://cdn-msp3.jmapiproxy3.cc',
    'https://cdn-msp2.jmapiproxy4.cc',
    'https://cdn-msp2.jmapiproxy3.cc',
  ];

  static const _jmAuthKey = '18comicAPPContent';
  static const _jmSecret = '185Hcomic3PAPP7R';
  static const _jmVersion = '1.7.2';

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro Build/TQ1A.230305.002; wv) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/114.0.5735.196 Safari/537.36';

  final http.Client _client;
  String _baseUrl;

  JmcomicService({String? baseUrl, http.Client? client})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? fallbackUrls[0];

  void dispose() => _client.close();

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
  Future<dynamic> _get(String path) async {
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final url = '$_baseUrl$path';
    final uri = Uri.parse(url);

    final response = await _client
        .get(uri, headers: _authHeaders(time))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException(
        'jmcomic API error: ${response.statusCode}',
        uri: uri,
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as String?;
    if (data == null || data.isEmpty) {
      throw Exception('Empty or invalid jmcomic response');
    }

    final decrypted = _decryptData(data, time);
    return jsonDecode(decrypted);
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
      return images
          .map((name) => PageUrl(_getPageUrl(name.toString(), chapterId)))
          .toList();
    } catch (e) {
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
          SelectFilterOption('成人A漫', '成人A漫', 'SelectOption'),
          SelectFilterOption('主題A漫', '主題A漫', 'SelectOption'),
          SelectFilterOption('角色扮演', '角色扮演', 'SelectOption'),
          SelectFilterOption('特殊PLAY', '特殊PLAY', 'SelectOption'),
          SelectFilterOption('其他', '其他', 'SelectOption'),
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
