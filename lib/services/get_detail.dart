import 'dart:async';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/services/built_in_sources.dart';
import 'package:mangayomi/services/isolate_service.dart';
import 'package:mangayomi/services/wogg/wogg_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'get_detail.g.dart';

@riverpod
Future<MManga> getDetail(
  Ref ref, {
  required String url,
  required Source source,
}) async {
  // Built-in sources: run in main isolate (no worker isolate HTTP issues).
  final bi = BuiltInSources.getForSource(source);
  if (bi != null) {
    if (bi.nameId == 'wogg') {
      final woggService = WoggService(baseUrl: bi.baseUrl);
      try {
        final detail = await woggService.getDetail(url);
        return detail ?? MManga(name: '未知', chapters: []);
      } finally {
        woggService.dispose();
      }
    }
  }

  final proxyServer = ref.read(androidProxyServerStateProvider);

  return getIsolateService.get<MManga>(
    url: url,
    source: source,
    serviceType: 'getDetail',
    proxyServer: proxyServer,
  );
}
