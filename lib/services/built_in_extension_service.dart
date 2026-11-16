import 'package:mangayomi/eval/interface.dart';
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/eval/model/m_pages.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/page.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/built_in_sources.dart';
import 'package:mangayomi/services/jmcomic/jmcomic_service.dart';
import 'package:mangayomi/services/wogg/wogg_service.dart';
import 'package:mangayomi/services/yydsys/yydsys_service.dart';

/// Extension-service facade for the built-in sources (wogg / jmcomic / yydsys).
///
/// Every provider in lib/services dispatches through `ExtensionService`, and
/// a built-in [Source] carries no `sourceCode`, so the interpreter-backed
/// services cannot run it. This facade is where the per-nameId dispatch that
/// used to be inlined in each provider lives once instead.
class BuiltInExtensionService implements ExtensionService {
  @override
  late Source source;
  final BuiltInSource bi;

  BuiltInExtensionService(this.source, this.bi);

  MPages _pages(List<Map<String, String>> items, {bool hasNext = true}) =>
      MPages(
        list: items
            .map(
              (e) => MManga(
                name: e['name'] ?? '',
                imageUrl: e['imageUrl'],
                link: e['link'] ?? '',
              ),
            )
            .toList(),
        hasNextPage: hasNext,
      );

  @override
  bool get supportsLatest => true;

  @override
  String get sourceBaseUrl => bi.baseUrl;

  @override
  Map<String, String> getHeaders() => {
    'Referer': bi.baseUrl,
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  @override
  FilterList getFilterList() {
    if (bi.nameId == 'wogg') return FilterList(WoggService.getFilterList());
    if (bi.nameId == 'jmcomic') {
      return FilterList(JmcomicService.getFilterList());
    }
    if (bi.nameId == 'yydsys') return FilterList(YydsysService.getFilterList());
    return FilterList(const []);
  }

  @override
  Future<MPages> getPopular(int page) async {
    final items = bi.nameId == 'wogg'
        ? await (WoggService(baseUrl: bi.baseUrl)..dispose()).getPopular()
        : bi.nameId == 'jmcomic'
        ? await (JmcomicService(baseUrl: bi.baseUrl)..dispose()).getPopular()
        : await YydsysService(baseUrl: bi.baseUrl).getPopular();
    return _pages(items);
  }

  @override
  Future<MPages> getLatestUpdates(int page) async {
    final items = bi.nameId == 'wogg'
        // wogg's catalog is newest-first already; the old provider mapped
        // "latest" onto its popular list.
        ? await (WoggService(baseUrl: bi.baseUrl)..dispose()).getPopular()
        : bi.nameId == 'jmcomic'
        ? await (JmcomicService(baseUrl: bi.baseUrl)..dispose())
              .getLatestUpdates(page)
        : await YydsysService(baseUrl: bi.baseUrl).getLatestUpdates(page);
    return _pages(items);
  }

  String _categoryOf(List<dynamic> filterList, String fallback) {
    for (final f in filterList) {
      if (f is SelectFilter && f.type == 'categories') {
        final selected = f.values[f.state] as SelectFilterOption;
        return selected.value;
      }
    }
    return fallback;
  }

  @override
  Future<MPages> search(
    String query,
    int page,
    List<dynamic> filterList,
  ) async {
    if (bi.nameId == 'wogg') {
      final s = WoggService(baseUrl: bi.baseUrl);
      try {
        return _pages(
          query.isEmpty && filterList.isNotEmpty
              ? await s.getCategoryList(_categoryOf(filterList, '1'), page)
              : await s.search(query, page),
        );
      } finally {
        s.dispose();
      }
    }
    if (bi.nameId == 'jmcomic') {
      final s = JmcomicService(baseUrl: bi.baseUrl);
      try {
        if (query.isEmpty && filterList.isNotEmpty) {
          final c = _categoryOf(filterList, 'all');
          return _pages(
            c == 'all'
                ? await s.getLatestUpdates(page)
                : await s.getCategoryList(c, page),
          );
        }
        return _pages(await s.search(query, page));
      } finally {
        s.dispose();
      }
    }
    final s = YydsysService(baseUrl: bi.baseUrl);
    return _pages(
      query.isEmpty && filterList.isNotEmpty
          ? await s.getCategoryList(_categoryOf(filterList, '1'), page)
          : await s.search(query, page),
    );
  }

  @override
  Future<MManga> getDetail(String url) async {
    if (bi.nameId == 'wogg') {
      final s = WoggService(baseUrl: bi.baseUrl);
      try {
        return (await s.getDetail(url)) ?? MManga(name: '未知', chapters: []);
      } finally {
        s.dispose();
      }
    }
    if (bi.nameId == 'jmcomic') {
      final s = JmcomicService(baseUrl: bi.baseUrl);
      try {
        return (await s.getDetail(url)) ?? MManga(name: '未知', chapters: []);
      } finally {
        s.dispose();
      }
    }
    return (await YydsysService(baseUrl: bi.baseUrl).getDetail(url)) ??
        MManga(name: '未知', chapters: []);
  }

  @override
  Future<List<PageUrl>> getPageList(String url) async {
    if (bi.nameId == 'jmcomic') {
      final s = JmcomicService(baseUrl: bi.baseUrl);
      try {
        return await s.getPageList(url);
      } finally {
        s.dispose();
      }
    }
    return const [];
  }

  @override
  Future<List<Video>> getVideoList(String url) async {
    if (bi.nameId == 'wogg') return WoggService.getVideoList(url);
    if (bi.nameId == 'yydsys') return YydsysService.getVideoList(url);
    return const [];
  }

  @override
  Future<String> getHtmlContent(String name, String url) async => '';

  @override
  Future<String> cleanHtmlContent(String html) async => html;

  @override
  List<SourcePreference> getSourcePreferences() => const [];

  @override
  void dispose() {}
}

/// The facade for [source] when it is a built-in source, else null.
BuiltInExtensionService? builtInServiceFor(Source? source) {
  final bi = source == null ? null : BuiltInSources.getForSource(source);
  return bi == null ? null : BuiltInExtensionService(source!, bi);
}
