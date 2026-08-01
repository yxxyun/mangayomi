import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_chapter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_manager.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_service.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

/// Built-in wogg server integration — runs in main isolate.
///
/// Fetches anime pages from wogg server, extracts Quark/UC share URLs,
/// and uses cloud drive services to get file lists.
class WoggService {
  /// Default wogg server URL — configurable via settings.
  static const String defaultBaseUrl = 'https://woggpan.333232.xyz';

  final String baseUrl;
  final http.Client _client;

  WoggService({this.baseUrl = defaultBaseUrl, http.Client? client})
      : _client = client ?? http.Client();

  void dispose() => _client.close();

  // ── Fetch detail page ──────────────────────────────────────────────

  /// Fetch a detail page from wogg and parse it into [MManga].
  ///
  /// [path] is the relative path from wogg (e.g. `/voddetail/128266.html`).
  Future<MManga?> getDetail(String path) async {
    final url = '$baseUrl$path';
    final body = await _get(url);
    final doc = html_parser.parse(body);

    // Parse metadata.
    final name = doc.querySelector('div.video-info .video-info-header h1')?.text;
    final imageUrl =
        doc.querySelector('div.video-cover .module-item-cover .module-item-pic img')?.attributes['data-src'];
    final description = doc.querySelector('div.video-info .video-info-content')?.text
        ?.replaceAll('[收起部分]', '')
        .replaceAll('[展开全部]', '')
        .trim();

    // Extract share URLs from the page.
    final shareUrls = <String>[];
    final shareElements = doc.querySelectorAll('div.module-row-one .module-row-info');
    for (final e in shareElements) {
      final text = e.querySelector('.module-row-title p')?.text ?? '';
      final quarkMatch = RegExp(r'(https://pan\.quark\.cn/s/[^"]+)').firstMatch(text);
      final ucMatch = RegExp(r'(https://drive\.uc\.cn/s/[^"]+)').firstMatch(text);
      final baiduMatch = RegExp(r'(https://pan\.baidu\.com/s/[^"]+)').firstMatch(text);
      if (quarkMatch != null) shareUrls.add(quarkMatch.group(1)!);
      if (ucMatch != null) shareUrls.add(ucMatch.group(1)!);
      if (baiduMatch != null) shareUrls.add(baiduMatch.group(1)!);
    }

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
      if (service == null || !service.isLoggedIn) continue;

      try {
        final files = await service.getFilesByShareUrl(url);
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
      } catch (_) {
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

  void _diag(String msg) {
    try {
      final f = File('${Directory.systemTemp.path}/mangayomi_wogg.log');
      f.writeAsStringSync('${DateTime.now()}: $msg\n', mode: FileMode.append);
    } catch (_) {}
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

  // ── Helpers ────────────────────────────────────────────────────────

  /// Get filter list for wogg (category filters).
  static List<dynamic> getFilterList() {
    return [
      SelectFilter(
        'categories',
        '影片類型',
        0,
        [
          SelectFilterOption('电影', '1', 'SelectOption'),
          SelectFilterOption('剧集', '2', 'SelectOption'),
          SelectFilterOption('动漫', '3', 'SelectOption'),
          SelectFilterOption('综艺', '4', 'SelectOption'),
          SelectFilterOption('音乐', '5', 'SelectOption'),
          SelectFilterOption('短剧', '6', 'SelectOption'),
          SelectFilterOption('臻彩视界', '44', 'SelectOption'),
        ],
        'SelectFilter',
      ),
    ];
  }

  /// Get category list from wogg (for filtered browsing).
  Future<List<Map<String, String>>> getCategoryList(String category, int page) async {
    final url = '$baseUrl/vodshow/$category--------$page---.html';
    final body = await _get(url);

    final doc = html_parser.parse(body);
    return _parseItemList(doc, 'div.module-item');
  }

  /// List popular content from wogg.
  Future<List<Map<String, String>>> getPopular() async {
    _diag('getPopular: $baseUrl');
    try {
      final body = await _get(baseUrl);
      _diag('getPopular: body length ${body.length}');

      final doc = html_parser.parse(body);
      final items = _parseItemList(doc, 'div.module-item');
      _diag('getPopular: found ${items.length} items');
      return items;
    } catch (e) {
      _diag('getPopular: ERROR $e');
      return [];
    }
  }

  /// Parse a list of items from HTML.
  List<Map<String, String>> _parseItemList(dynamic doc, String selector) {
    final items = <Map<String, String>>[];
    final elements = doc.querySelectorAll(selector);
    if (elements.isNotEmpty) {
      final first = elements.first;
      _diag('HTML sample: ${first.outerHtml.substring(0, first.outerHtml.length.clamp(0, 500))}');
    }

    for (final element in elements) {
      final name = element.querySelector('.module-item-cover .module-item-pic a')?.attributes['title'];
      var imageUrl = element.querySelector('.module-item-cover .module-item-pic img')?.attributes['data-src'];
      final link = element.querySelector('.module-item-cover .module-item-pic a')?.attributes['href'];
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

    _diag('parsed ${items.length} items, first imageUrl: ${items.isNotEmpty ? items[0]['imageUrl'] : "none"}');
    return items;
  }

  /// Search wogg for content.
  Future<List<Map<String, String>>> search(String query, int page) async {
    final url = '$baseUrl/vodsearch/$query----------$page---.html';
    final body = await _get(url);

    final doc = html_parser.parse(body);
    final items = <Map<String, String>>[];

    for (final element in doc.querySelectorAll('.module-search-item')) {
      final name = element.querySelector('.video-info .video-info-header a')?.attributes['title'];
      final imageUrl = element.querySelector('.video-cover .module-item-cover .module-item-pic img')?.attributes['data-src'];
      final link = element.querySelector('.video-info .video-info-header a')?.attributes['href'];
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
}
