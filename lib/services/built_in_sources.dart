import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';

/// Registry of built-in sources that don't require extensions.
///
/// Each built-in source has a unique [nameId] used for identification
/// across the app (detail page, video list, catalog, etc.).
class BuiltInSource {
  final String nameId;
  final String name;
  final String lang;
  final String baseUrl;
  final String iconUrl;
  final ItemType itemType;
  final bool isNsfw;

  const BuiltInSource({
    required this.nameId,
    required this.name,
    required this.lang,
    required this.baseUrl,
    required this.iconUrl,
    this.itemType = ItemType.anime,
    this.isNsfw = false,
  });

  /// Convert to a [Source] model for use in the UI.
  Source toSource() => Source(
        name: name,
        lang: lang,
        baseUrl: baseUrl,
        iconUrl: iconUrl,
        itemType: itemType,
        isNsfw: isNsfw,
      );
}

/// All registered built-in sources.
class BuiltInSources {
  BuiltInSources._();

  static const wogg = BuiltInSource(
    nameId: 'wogg',
    name: '玩偶哥哥',
    lang: 'zh',
    baseUrl: 'https://woggpan.333232.xyz',
    iconUrl:
        'https://imgsrc.baidu.com/forum/pic/item/4b90f603738da977d5da660af651f8198618e31f.jpg',
    itemType: ItemType.anime,
  );

  static const jmcomic = BuiltInSource(
    nameId: 'jmcomic',
    name: '禁漫天堂',
    lang: 'zh',
    baseUrl: 'https://www.cdnhjk.net',
    iconUrl:
        'https://cdn-msp.jmapiproxy3.cc/media/albums/511146_3x4.jpg',
    itemType: ItemType.manga,
    isNsfw: true,
  );

  static const yydsys = BuiltInSource(
    nameId: 'yydsys',
    name: '多多影音',
    lang: 'zh',
    baseUrl: 'https://tv.yydsys.top',
    iconUrl:
        'https://tv.yydsys.top/template/DYXS2/static/picture/logo.png',
    itemType: ItemType.anime,
  );

  /// All built-in sources.
  static const all = [wogg, jmcomic, yydsys];

  /// Lookup by [nameId].
  static BuiltInSource? findById(String nameId) {
    for (final s in all) {
      if (s.nameId == nameId) return s;
    }
    return null;
  }

  /// Check if a [Source] is a built-in source.
  static bool isBuiltIn(Source source) {
    return all.any((s) => s.name == source.name && s.lang == source.lang);
  }

  /// Get the built-in source for a [Source], or null.
  static BuiltInSource? getForSource(Source source) {
    for (final s in all) {
      if (s.name == source.name && s.lang == source.lang) return s;
    }
    return null;
  }
}
