import 'dart:math';

import 'package:isar_community/isar.dart';
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
import 'package:mangayomi/services/yydsys/yydsys_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'get_latest_updates.g.dart';

@riverpod
Future<MPages?> getLatestUpdates(
  Ref ref, {
  required Source source,
  required int page,
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
                .sortByDateAddedDesc()
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
        final items = await woggService.getPopular();
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
        final items = await jmcomicService.getLatestUpdates(page);
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
    } else if (bi.nameId == 'yydsys') {
      final yydsysService = YydsysService(baseUrl: bi.baseUrl);
      try {
        final items = await yydsysService.getLatestUpdates(page);
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
      }
    }
  }

  return getIsolateService.get<MPages?>(
    page: page,
    source: source,
    serviceType: 'getLatestUpdates',
    proxyServer: ref.read(androidProxyServerStateProvider),
  );
}
