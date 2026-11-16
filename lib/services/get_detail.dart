import 'dart:async';

import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/providers/browse_state_provider.dart';
import 'package:mangayomi/services/built_in_extension_service.dart';
import 'package:mangayomi/services/isolate_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'get_detail.g.dart';

@riverpod
Future<MManga> getDetail(
  Ref ref, {
  required String url,
  required Source source,
}) async {
  // Built-in sources: run in main isolate (no worker isolate HTTP issues).
  // Built-in sources have no sourceCode, so no isolate can run them.
  final builtIn = builtInServiceFor(source);
  if (builtIn != null) {
    try {
      return await builtIn.getDetail(url);
    } catch (e) {
      return MManga(name: '未知', chapters: []);
    } finally {
      builtIn.dispose();
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
