import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/library/providers/isar_providers.dart';
import 'package:mangayomi/modules/library/providers/library_state_provider.dart';
import 'package:mangayomi/modules/library/widgets/library_body.dart';
import 'package:mangayomi/modules/library/widgets/library_dialogs.dart';
import 'package:mangayomi/modules/library/widgets/library_settings_sheet.dart';
import 'package:mangayomi/modules/more/providers/downloaded_only_state_provider.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/modules/widgets/error_text.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/library_updater.dart';

/// Reusable library content widget designed for use in a BottomSheet.
class LibraryBottomSheetContent extends ConsumerStatefulWidget {
  final ItemType itemType;
  final ScrollController scrollController;

  const LibraryBottomSheetContent({
    super.key,
    required this.itemType,
    required this.scrollController,
  });

  @override
  ConsumerState<LibraryBottomSheetContent> createState() =>
      _LibraryBottomSheetContentState();
}

class _LibraryBottomSheetContentState
    extends ConsumerState<LibraryBottomSheetContent> {
  @override
  Widget build(BuildContext context) {
    final settingsStream = ref.watch(getSettingsStreamProvider);

    return settingsStream.when(
      data: (settingsList) {
        final settings = settingsList.first;
        return _Content(
          itemType: widget.itemType,
          settings: settings,
          scrollController: widget.scrollController,
        );
      },
      error: (e, _) => ErrorText(e),
      loading: () => const ProgressCenter(),
    );
  }
}

class _Content extends ConsumerStatefulWidget {
  final ItemType itemType;
  final Settings settings;
  final ScrollController scrollController;

  const _Content({
    required this.itemType,
    required this.settings,
    required this.scrollController,
  });

  @override
  ConsumerState<_Content> createState() => _ContentState();
}

class _ContentState extends ConsumerState<_Content>
    with TickerProviderStateMixin {
  final _entries = <Manga>[];
  bool _isSearch = false;
  final _textEditingController = TextEditingController();

  @override
  void dispose() {
    _textEditingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final displayType = ref.watch(
      libraryDisplayTypeStateProvider(
        itemType: widget.itemType,
        settings: widget.settings,
      ),
    );
    final isNotFiltering = ref.watch(
      mangasFilterResultStateProvider(
        itemType: widget.itemType,
        mangaList: _entries,
        settings: widget.settings,
      ),
    );
    final mangaAll = ref.watch(
      getAllMangaStreamProvider(
        categoryId: null,
        itemType: widget.itemType,
      ),
    );

    return Column(
      children: [
        // Header bar
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              if (_isSearch)
                Expanded(
                  child: TextField(
                    controller: _textEditingController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: l10n.search,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _textEditingController.clear();
                          setState(() => _isSearch = false);
                        },
                      ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                )
              else ...[
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => setState(() => _isSearch = true),
                ),
                const Spacer(),
                Text(
                  l10n.library,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.filter_list_sharp,
                    color: isNotFiltering ? null : Colors.yellow,
                  ),
                  onPressed: () {
                    showLibrarySettingsSheet(
                      context: context,
                      vsync: this,
                      settings: widget.settings,
                      itemType: widget.itemType,
                      entries: _entries,
                    );
                  },
                ),
                PopupMenuButton(
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 0,
                      child: Text(l10n.update_library),
                    ),
                    PopupMenuItem(
                      value: 1,
                      child: Text(l10n.import),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 0) {
                      mangaAll.whenData((data) {
                        updateLibrary(
                          ref: ref,
                          context: context,
                          mangaList: data,
                          itemType: widget.itemType,
                        );
                      });
                    } else if (value == 1) {
                      showImportLocalDialog(context, widget.itemType);
                    }
                  },
                ),
              ],
            ],
          ),
        ),
        // Library body
        Expanded(
          child: mangaAll.when(
            data: (man) {
              return LibraryBody(
                itemType: widget.itemType,
                categoryId: null,
                downloadFilterType: ref.watch(
                  mangaFilterDownloadedStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                unreadFilterType: ref.watch(
                  mangaFilterUnreadStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                startedFilterType: ref.watch(
                  mangaFilterStartedStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                bookmarkedFilterType: ref.watch(
                  mangaFilterBookmarkedStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                completedFilterType: ref.watch(
                  mangaFilterCompletedStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                trackingFilterType: ref.watch(
                  mangaFilterTrackingStateProvider(
                    itemType: widget.itemType,
                    mangaList: _entries,
                    settings: widget.settings,
                  ),
                ),
                reverse: ref.watch(
                  sortLibraryMangaStateProvider(
                    itemType: widget.itemType,
                    settings: widget.settings,
                  ),
                ).reverse ?? false,
                downloadedChapter: ref.watch(
                  libraryDownloadedChaptersStateProvider(
                    itemType: widget.itemType,
                    settings: widget.settings,
                  ),
                ),
                continueReaderBtn: ref.watch(
                  libraryShowContinueReadingButtonStateProvider(
                    itemType: widget.itemType,
                    settings: widget.settings,
                  ),
                ),
                localSource: ref.watch(
                  libraryLocalSourceStateProvider(
                    itemType: widget.itemType,
                    settings: widget.settings,
                  ),
                ),
                language: ref.watch(
                  libraryLanguageStateProvider(
                    itemType: widget.itemType,
                    settings: widget.settings,
                  ),
                ),
                displayType: displayType,
                settings: widget.settings,
                downloadedOnly: ref.watch(downloadedOnlyStateProvider),
                searchQuery: _textEditingController.text,
                ignoreFiltersOnSearch: _textEditingController.text.isNotEmpty,
              );
            },
            error: (e, _) => ErrorText(e),
            loading: () => const ProgressCenter(),
          ),
        ),
      ],
    );
  }
}
