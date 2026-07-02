import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/history/providers/isar_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/utils/cached_network.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/date.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';

/// Reusable history content widget designed for use in a BottomSheet.
class HistoryBottomSheetContent extends ConsumerStatefulWidget {
  final ItemType itemType;
  final ScrollController scrollController;

  const HistoryBottomSheetContent({
    super.key,
    required this.itemType,
    required this.scrollController,
  });

  @override
  ConsumerState<HistoryBottomSheetContent> createState() =>
      _HistoryBottomSheetContentState();
}

class _HistoryBottomSheetContentState
    extends ConsumerState<HistoryBottomSheetContent> {
  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final history = ref.watch(
      getAllHistoryStreamProvider(
        itemType: widget.itemType,
        search: '',
      ),
    );

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              const Spacer(),
              Text(
                l10n.history,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _clearHistory(),
              ),
            ],
          ),
        ),
        const Divider(),
        // History list
        Expanded(
          child: history.when(
            data: (entries) {
              if (entries.isEmpty) {
                return Center(child: Text(l10n.nothing_read_recently));
              }
              return ListView.builder(
                controller: widget.scrollController,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final element = entries[index];
                  final chapter = element.chapter.value!;
                  final manga = chapter.manga.value!;
                  return _HistoryItem(
                    manga: manga,
                    chapter: chapter,
                    element: element,
                    onDelete: () => _deleteEntry(element.id!),
                    onTapChapter: () =>
                        chapter.pushToReaderView(context),
                    onTapManga: () => context.push(
                      '/manga-reader/detail',
                      extra: manga.id,
                    ),
                  );
                },
              );
            },
            error: (_, _) =>
                Center(child: Text(l10n.nothing_read_recently)),
            loading: () => const Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10nLocalizations(context)!.remove_everything),
        content: Text(l10nLocalizations(context)!.remove_everything_msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10nLocalizations(context)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10nLocalizations(context)!.ok),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final histories = await isar.historys
          .filter()
          .idIsNotNull()
          .chapter(
            (q) => q.manga(
              (q) => q.itemTypeEqualTo(widget.itemType),
            ),
          )
          .findAll();
      final ids = histories.map((h) => h.id!).toList();
      await isar.writeTxn(() => isar.historys.deleteAll(ids));
    }
  }

  Future<void> _deleteEntry(int id) async {
    isar.writeTxnSync(() {
      isar.historys.deleteSync(id);
      ref
          .read(synchingProvider(syncId: 1).notifier)
          .addChangedPart(ActionType.removeHistory, id, '{}', false);
    });
  }
}

class _HistoryItem extends StatelessWidget {
  final Manga manga;
  final Chapter chapter;
  final History element;
  final VoidCallback onDelete;
  final VoidCallback onTapChapter;
  final VoidCallback onTapManga;

  const _HistoryItem({
    required this.manga,
    required this.chapter,
    required this.element,
    required this.onDelete,
    required this.onTapChapter,
    required this.onTapManga,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTapChapter,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              // Cover
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 50,
                  height: 70,
                  child: _coverImage(context),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      manga.name ?? '',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${chapter.name} - ${dateFormatHour(element.date!, context)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverImage(BuildContext context) {
    if (manga.customCoverImage != null) {
      return Image.memory(
        manga.customCoverImage as Uint8List,
        fit: BoxFit.cover,
      );
    }
    return cachedCompressedNetworkImage(
      headers: null,
      imageUrl: toImgUrl(manga.customCoverFromTracker ?? manga.imageUrl ?? ''),
      width: 50,
      height: 70,
      fit: BoxFit.cover,
    );
  }
}
