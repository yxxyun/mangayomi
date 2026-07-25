import 'dart:math';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/eval/model/m_pages.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/services/built_in_sources.dart';
import 'package:mangayomi/services/isolate_service.dart';
import 'package:mangayomi/services/jmcomic/jmcomic_service.dart';
import 'package:mangayomi/services/wogg/wogg_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'search.g.dart';

@riverpod
Future<MPages?> search(
  Ref ref, {
  required Source source,
  required String query,
  required int page,
  required List<dynamic> filterList,
}) async {
  if (source.name == "local" && source.lang == "") {
    final result =
        (await isar.mangas
                .filter()
                .itemTypeEqualTo(source.itemType)
                .group(
                  (q) => q
                      .sourceEqualTo("local")
                      .or()
                      .linkContains("Mangayomi/local")
                      .or()
                      .linkContains("Mangayomi\\local"),
                )
                .nameContains(query, caseSensitive: false)
                .offset(max(0, page - 1) * 50)
                .limit(50)
                .findAll())
            .map((e) => MManga(name: e.name))
            .toList();
    return MPages(list: result, hasNextPage: true);
  }

  // Built-in sources: run in main isolate.
  if (BuiltInSources.isBuiltIn(source)) {
    final bi = BuiltInSources.getForSource(source)!;
    if (bi.nameId == 'wogg') {
      final woggService = WoggService(baseUrl: bi.baseUrl);
      try {
        List<Map<String, String>> items;
        if (query.isEmpty && filterList.isNotEmpty) {
          String category = '1';
          for (final f in filterList) {
            if (f is SelectFilter && f.type == 'categories') {
              final selected = f.values[f.state] as SelectFilterOption;
              category = selected.value;
            }
          }
          items = await woggService.getCategoryList(category, page);
        } else {
          items = await woggService.search(query, page);
        }
        final result = items
            .map((e) => MManga(
                  name: e['name'],
                  imageUrl: e['imageUrl'],
                  link: e['link'],
                ))
            .toList();
        return MPages(list: result, hasNextPage: true);
      } catch (e) {
        return MPages(list: [], hasNextPage: false);
      } finally {
        woggService.dispose();
      }
    } else if (bi.nameId == 'jmcomic') {
      final jmcomicService = JmcomicService(baseUrl: bi.baseUrl);
      try {
        List<Map<String, String>> items;
        if (query.isEmpty && filterList.isNotEmpty) {
          String category = 'all';
          for (final f in filterList) {
            if (f is SelectFilter && f.type == 'categories') {
              final selected = f.values[f.state] as SelectFilterOption;
              category = selected.value;
            }
          }
          if (category == 'all') {
            items = await jmcomicService.getLatestUpdates(page);
          } else {
            items = await jmcomicService.getCategoryList(category, page);
          }
        } else {
          items = await jmcomicService.search(query, page);
        }
        final result = items
            .map((e) => MManga(
                  name: e['name'],
                  imageUrl: e['imageUrl'],
                  link: e['link'],
                ))
            .toList();
        return MPages(list: result, hasNextPage: true);
      } catch (e) {
        return MPages(list: [], hasNextPage: false);
      } finally {
        jmcomicService.dispose();
      }
    }
  }

  return getIsolateService.get<MPages?>(
    query: query,
    filterList: filterList,
    source: source,
    page: page,
    serviceType: 'search',
    proxyServer: ref.read(androidProxyServerStateProvider),
  );
}
