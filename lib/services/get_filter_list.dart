import 'package:mangayomi/eval/lib.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/built_in_sources.dart';
import 'package:mangayomi/services/jmcomic/jmcomic_service.dart';
import 'package:mangayomi/services/wogg/wogg_service.dart';
import 'package:mangayomi/services/yydsys/yydsys_service.dart';

List<dynamic> getFilterList({required Source source}) {
  // Built-in sources: return category filters.
  if (BuiltInSources.isBuiltIn(source)) {
    final bi = BuiltInSources.getForSource(source);
    if (bi?.nameId == 'wogg') {
      return WoggService.getFilterList();
    } else if (bi?.nameId == 'jmcomic') {
      return JmcomicService.getFilterList();
    } else if (bi?.nameId == 'yydsys') {
      return YydsysService.getFilterList();
    }
    return [];
  }

  return getCachedExtensionService(source, "").getFilterList().filters;
}
