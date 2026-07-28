import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/browse/sources/sources_screen.dart';
import 'package:mangayomi/modules/browse/extension/extension_screen.dart';
import 'package:mangayomi/modules/home/widgets/library_bottom_sheet_content.dart';
import 'package:mangayomi/modules/home/widgets/history_bottom_sheet_content.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/utils/item_type_localization.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

/// Main page for each content type (Anime/Manga/Novel).
///
/// Top bar: type title + Library / History buttons
/// Body: two tabs — Browse (installed sources) and Manage (extensions)
class TypeHomeScreen extends ConsumerStatefulWidget {
  final ItemType itemType;

  const TypeHomeScreen({super.key, required this.itemType});

  @override
  ConsumerState<TypeHomeScreen> createState() => _TypeHomeScreenState();
}

class _TypeHomeScreenState extends ConsumerState<TypeHomeScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showLibrarySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 1.0,
        expand: false,
        builder: (context, scrollController) {
          return LibraryBottomSheetContent(
            itemType: widget.itemType,
            scrollController: scrollController,
          );
        },
      ),
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 1.0,
        expand: false,
        builder: (context, scrollController) {
          return HistoryBottomSheetContent(
            itemType: widget.itemType,
            scrollController: scrollController,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context);
    if (l10n == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        title: Text(
          widget.itemType.localized(l10n),
          style: TextStyle(color: context.textColor),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.collections_bookmark_outlined),
            tooltip: l10n.library,
            onPressed: _showLibrarySheet,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.history,
            onPressed: _showHistorySheet,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
          Tab(text: l10n.sources),
          Tab(text: l10n.extensions),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          SourcesScreen(
            itemType: widget.itemType,
            tabIndex: (i) => _tabController!.animateTo(i),
            tabs: const [],
          ),
          ExtensionScreen(
            itemType: widget.itemType,
            query: '',
          ),
        ],
      ),
    );
  }
}
