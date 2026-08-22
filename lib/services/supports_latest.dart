import 'package:mangayomi/eval/lib.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/services/built_in_sources.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'supports_latest.g.dart';

@riverpod
bool supportsLatest(Ref ref, {required Source source}) {
  // Built-in sources support latest.
  if (BuiltInSources.isBuiltIn(source)) return true;

  final androidProxy = ref.read(androidProxyServerStateProvider);
  return getCachedExtensionService(source, androidProxy).supportsLatest;
}
