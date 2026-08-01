import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:html/parser.dart' as html_parser;
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_chapter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_manager.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

void _ydDiag(String msg) {
  try {
    final f = File('${Directory.systemTemp.path}/mangayomi_yydsys.log');
    f.writeAsStringSync('${DateTime.now()}: $msg\n', mode: FileMode.append);
  } catch (_) {}
}

/// Built-in 多多影音 (yydsys) integration — runs in main isolate.
///
/// Fetches movie/anime pages from the yydsys site, extracts Quark/UC share
/// URLs, and uses cloud drive services to get file lists and videos.
class YydsysService {
  /// Default server URL — the site exposes several mirrors.
  static const String defaultBaseUrl = 'https://tv.yydsys.top';

  /// All known mirror domains.
  static const List<String> mirrorUrls = [
    'https://tv.yydsys.top',
    'https://tv.yydsys.cc',
    'https://tv.214521.xyz',
  ];

  final String baseUrl;

  YydsysService({this.baseUrl = defaultBaseUrl});

  // ── Fetch detail page ──────────────────────────────────────────────

  /// Fetch a detail page and parse it into [MManga].
  ///
  /// [path] is the relative path from the site (e.g. `/index.php/vod/detail/id/123.html`).
  Future<MManga?> getDetail(String path) async {
    final url = '$baseUrl$path';
    final body = await _get(url);
    final doc = html_parser.parse(body);

    final name = doc
        .querySelector('div.video-info .video-info-header h1')
        ?.text
        ?.trim();
    final imageUrl = doc
        .querySelector('div.video-cover .module-item-cover .module-item-pic img')
        ?.attributes['data-src'];
    final description = doc
        .querySelector('div.video-info .video-info-content')
        ?.text
        ?.replaceAll('[收起部分]', '')
        .replaceAll('[展开全部]', '')
        .trim();

    // Extract share URLs from the page.
    final shareUrls = <String>[];
    final shareElements =
        doc.querySelectorAll('div.module-row-one .module-row-info');
    for (final e in shareElements) {
      final text = e.querySelector('.module-row-title p')?.text ?? '';
      final quarkMatch =
          RegExp(r'(https://pan\.quark\.cn/s/[^"]+)').firstMatch(text);
      final ucMatch = RegExp(r'(https://drive\.uc\.cn/s/[^"]+)').firstMatch(text);
      final baiduMatch =
          RegExp(r'(https://pan\.baidu\.com/s/[^"]+)').firstMatch(text);
      if (quarkMatch != null) shareUrls.add(quarkMatch.group(1)!);
      if (ucMatch != null) shareUrls.add(ucMatch.group(1)!);
      if (baiduMatch != null) shareUrls.add(baiduMatch.group(1)!);
    }
    _ydDiag('getDetail $path: shareUrls=$shareUrls');

    if (shareUrls.isEmpty) return null;

    // Get file lists from cloud drive services.
    final episodes = await _getEpisodesFromShareUrls(shareUrls);

    return MManga(
      name: name,
      imageUrl: imageUrl,
      description: description,
      link: path,
      chapters: episodes,
    );
  }

  // ── Cloud drive integration ────────────────────────────────────────

  /// Convert share URLs to [MChapter] episodes via cloud drive services.
  Future<List<MChapter>> _getEpisodesFromShareUrls(List<String> shareUrls) async {
    final episodes = <MChapter>[];

    for (final url in shareUrls) {
      final type = CloudDriveManager.detectType(url);
      if (type == null) continue;

      final service = CloudDriveManager.instance.get(type);
      _ydDiag('share $url type=$type service=${service != null} loggedIn=${service?.isLoggedIn}');
      if (service == null || !service.isLoggedIn) continue;

      try {
        final files = await service.getFilesByShareUrl(url);
        _ydDiag('share $url files=${files.length}');
        for (final file in files) {
          if (!file.isDir) {
            final epUrl = file.getEpisodeUrl('电影');
            final parts = epUrl.split('\$');
            episodes.add(MChapter(
              name: parts.isNotEmpty ? parts[0].trim() : file.name,
              url: epUrl,
              scanlator: '网盘',
            ));
          }
        }
      } catch (e) {
        _ydDiag('share $url ERROR: $e');
        // Skip failed share URLs.
      }
    }

    return episodes;
  }

  // ── Video list ─────────────────────────────────────────────────────

  /// Get video list for an encoded episode URL.
  ///
  /// The [encodedUrl] format is: `[quark] name$quark++fileId++...`
  static Future<List<Video>> getVideoList(String encodedUrl) async {
    final typeMatch = RegExp(r'\[(\w+)\]').firstMatch(encodedUrl);
    if (typeMatch == null) return [];

    final typeKey = typeMatch.group(1)!;
    final cloudType = CloudDriveType.fromKey(typeKey);
    if (cloudType == null) return [];

    final service = CloudDriveManager.instance.get(cloudType);
    if (service == null) return [];

    try {
      return await service.getVideos(encodedUrl);
    } catch (_) {
      return [];
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  /// Get filter list for yydsys (category filters).
  static List<dynamic> getFilterList() {
    return [
      SelectFilter(
        'categories',
        '影片類型',
        0,
        [
          SelectFilterOption('电影', '1', 'SelectOption'),
          SelectFilterOption('剧集', '2', 'SelectOption'),
          SelectFilterOption('动漫', '4', 'SelectOption'),
          SelectFilterOption('综艺', '3', 'SelectOption'),
          SelectFilterOption('短剧', '5', 'SelectOption'),
          SelectFilterOption('纪录片', '20', 'SelectOption'),
        ],
        'SelectFilter',
      ),
    ];
  }

  /// Get category list from yydsys (for filtered browsing).
  Future<List<Map<String, String>>> getCategoryList(
    String category,
    int page,
  ) async {
    final url =
        '$baseUrl/index.php/vod/show/id/$category/page/$page.html';
    final body = await _get(url);

    final doc = html_parser.parse(body);
    return _parseItemList(doc, 'div.module-item');
  }

  /// List popular content from the yydsys homepage.
  Future<List<Map<String, String>>> getPopular() async {
    final body = await _get(baseUrl);
    final doc = html_parser.parse(body);
    return _parseItemList(doc, 'div.module-item');
  }

  /// Latest updates (id=1 is the default movie category).
  Future<List<Map<String, String>>> getLatestUpdates(int page) async {
    final url =
        '$baseUrl/index.php/vod/show/id/1/page/$page.html';
    final body = await _get(url);
    final doc = html_parser.parse(body);
    return _parseItemList(doc, 'div.module-item');
  }

  /// Search yydsys for content.
  Future<List<Map<String, String>>> search(String query, int page) async {
    final url = '$baseUrl/index.php/vod/search/page/$page/wd/$query.html';
    final body = await _get(url);

    final doc = html_parser.parse(body);
    final items = <Map<String, String>>[];

    for (final element in doc.querySelectorAll('.module-search-item')) {
      final name =
          element.querySelector('.video-info .video-info-header a')?.attributes['title'];
      final imageUrl = element
          .querySelector('.video-cover .module-item-cover .module-item-pic img')
          ?.attributes['data-src'];
      final link =
          element.querySelector('.video-info .video-info-header a')?.attributes['href'];
      if (name != null && link != null) {
        items.add({
          'name': name,
          'imageUrl': imageUrl ?? '',
          'link': link,
        });
      }
    }

    return items;
  }

  /// Parse a list of items from HTML.
  List<Map<String, String>> _parseItemList(dynamic doc, String selector) {
    final items = <Map<String, String>>[];

    for (final element in doc.querySelectorAll(selector)) {
      final name = element
          .querySelector('.module-item-cover .module-item-pic a')
          ?.attributes['title'];
      var imageUrl = element
          .querySelector('.module-item-cover .module-item-pic img')
          ?.attributes['data-src'];
      final link = element
          .querySelector('.module-item-cover .module-item-pic a')
          ?.attributes['href'];
      if (name != null && link != null) {
        // Make relative image URLs absolute.
        if (imageUrl != null && !imageUrl.startsWith('http')) {
          imageUrl = '$baseUrl$imageUrl';
        }
        items.add({
          'name': name,
          'imageUrl': imageUrl ?? '',
          'link': link,
        });
      }
    }

    return items;
  }

  /// HTTP GET with timeout — uses dart:io HttpClient for better control.
  Future<String> _get(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set('Referer', '$baseUrl/');
      request.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      return body;
    } finally {
      client.close(force: true);
    }
  }
}
