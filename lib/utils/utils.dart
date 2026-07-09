import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/built_in_sources.dart';

Source? getSource(
  String lang,
  String name,
  int? sourceId, {
  bool installedOnly = false,
}) {
  // Check built-in sources first.
  for (final bi in BuiltInSources.all) {
    if (bi.name == name && bi.lang == lang) {
      return bi.toSource();
    }
  }

  try {
    var sourcesFilter = isar.sources.filter().idIsNotNull();
    if (installedOnly) {
      sourcesFilter = sourcesFilter.isActiveEqualTo(true).isAddedEqualTo(true);
    }
    final sourcesList = sourcesFilter.findAllSync();
    return sourcesList.firstWhere(
      (element) => sourceId != null
          ? element.id == sourceId && element.sourceCode != null
          : element.name!.toLowerCase() == name.toLowerCase() &&
                element.lang == lang &&
                element.sourceCode != null,
      orElse: () => throw ("Error when getting source"),
    );
  } catch (_) {
    return null;
  }
}
