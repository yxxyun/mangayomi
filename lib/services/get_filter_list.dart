import 'package:mangayomi/eval/lib.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/source_code_errors.dart';
import 'package:mangayomi/services/built_in_extension_service.dart';

/// The source's search filters, or none when its code will not run (empty,
/// broken, half installed): the screens that ask, a source's home among
/// them, then open and say why it gives nothing, rather than failing to
/// build.
List<dynamic> getFilterList({required Source source}) {
  final builtIn = builtInServiceFor(source);
  if (builtIn != null) {
    final f = builtIn.getFilterList().filters;
    builtIn.dispose();
    return f;
  }
  try {
    final filters = getCachedExtensionService(
      source,
      "",
    ).getFilterList().filters;
    SourceCodeErrors.clear(source.id);
    return filters;
  } catch (e, stack) {
    SourceCodeErrors.report(source, 'Filters', e, stack);
    return [];
  }
}
