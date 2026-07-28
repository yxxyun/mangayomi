import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/modules/more/about/providers/download_file_screen.dart';
import 'package:mangayomi/modules/more/about/providers/check_for_update.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/auto_backup.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/services/sync_server.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/router/router.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';
import 'package:mangayomi/models/manga.dart';

/// Shell widget for the 4-tab navigation.
///
/// Tabs: Anime, Manga, Novel, Settings
/// Responsive: NavigationBar (mobile) / NavigationRail (tablet)
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  Timer? _backupTimer;
  Timer? _syncTimer;

  static const _tabRoutes = ['/anime', '/manga', '/novel', '/more'];
  static const _readerRoutes = [
    '/mangaReaderView',
    '/animePlayerView',
    '/novelReaderView',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initialize();
    });
    discordRpc?.connect(ref);
  }

  void _initialize() {
    _backupTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => ref.read(checkAndBackupProvider),
    );
    final autoSyncFrequency =
        ref.read(synchingProvider(syncId: 1)).autoSyncFrequency;
    if (autoSyncFrequency != 0) {
      _syncTimer = Timer.periodic(
        Duration(seconds: autoSyncFrequency),
        (timer) => _onSyncTimerTick(timer),
      );
    }
    Future.microtask(() {
      if (mounted) {
        for (final type in ItemType.values) {
          ref.read(
            fetchItemSourcesListProvider(
              id: null,
              reFresh: false,
              itemType: type,
            ),
          );
        }
      }
    });
  }

  void _onSyncTimerTick(Timer timer) {
    if (!mounted) return timer.cancel();
    try {
      ref.read(syncServerProvider(syncId: 1).notifier).startSync(
        l10nLocalizations(context)!,
        true,
      );
    } catch (e) {
      botToast(
        'Failed to sync! Maybe the sync server is down. '
        'Restart the app to resume auto sync.',
      );
      timer.cancel();
    }
  }

  @override
  void dispose() {
    _backupTimer?.cancel();
    _syncTimer?.cancel();
    discordRpc?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<UpdateInfo?>>(checkForUpdateProvider, (_, next) {
      next.whenData((updateInfo) {
        if (updateInfo != null && context.mounted) {
          showDialog(
            context: context,
            builder: (_) => DownloadFileScreen(updateAvailable: updateInfo),
          );
        }
      });
    });

    final location = ref.watch(routerCurrentLocationStateProvider);

    // When in a reader/viewer route, hide the navigation shell entirely.
    if (location != null && _readerRoutes.contains(location)) {
      return widget.navigationShell;
    }

    final shell = widget.navigationShell;
    return Scaffold(
      body: context.isTablet ? _tabletLayout(shell) : shell,
      bottomNavigationBar:
          context.isTablet ? null : _mobileBottomNav(shell),
    );
  }

  Widget _tabletLayout(StatefulNavigationShell shell) {
    return Row(
      children: [
        NavigationRail(
          labelType: NavigationRailLabelType.all,
          useIndicator: true,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          destinations: _buildRailDestinations(),
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (index) =>
              shell.goBranch(index, initialLocation: index == shell.currentIndex),
        ),
        Expanded(child: shell),
      ],
    );
  }

  Widget _mobileBottomNav(StatefulNavigationShell shell) {
    return NavigationBar(
      selectedIndex: shell.currentIndex,
      animationDuration: const Duration(milliseconds: 300),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
      ),
      destinations: _buildNavDestinations(),
      onDestinationSelected: (index) =>
          shell.goBranch(index, initialLocation: index == shell.currentIndex),
    );
  }

  List<NavigationRailDestination> _buildRailDestinations() {
    final loc = l10nLocalizations(context);
    // Fallback labels if l10n not yet available
    const fallback = ['Anime', 'Manga', 'Novel', 'More'];
    final labels = loc != null ? [loc.anime, loc.manga, loc.novel, loc.more] : fallback;
    return [
      NavigationRailDestination(
        icon: const Icon(Icons.video_collection_outlined),
        selectedIcon: const Icon(Icons.video_collection),
        label: Text(labels[0]),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.collections_bookmark_outlined),
        selectedIcon: const Icon(Icons.collections_bookmark),
        label: Text(labels[1]),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.local_library_outlined),
        selectedIcon: const Icon(Icons.local_library),
        label: Text(labels[2]),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.more_horiz_outlined),
        selectedIcon: const Icon(Icons.more_horiz),
        label: Text(labels[3]),
      ),
    ];
  }

  List<NavigationDestination> _buildNavDestinations() {
    final loc = l10nLocalizations(context);
    const fallback = ['Anime', 'Manga', 'Novel', 'More'];
    final labels = loc != null ? [loc.anime, loc.manga, loc.novel, loc.more] : fallback;
    return [
      NavigationDestination(
        icon: const Icon(Icons.video_collection_outlined),
        selectedIcon: const Icon(Icons.video_collection),
        label: labels[0],
      ),
      NavigationDestination(
        icon: const Icon(Icons.collections_bookmark_outlined),
        selectedIcon: const Icon(Icons.collections_bookmark),
        label: labels[1],
      ),
      NavigationDestination(
        icon: const Icon(Icons.local_library_outlined),
        selectedIcon: const Icon(Icons.local_library),
        label: labels[2],
      ),
      NavigationDestination(
        icon: const Icon(Icons.more_horiz_outlined),
        selectedIcon: const Icon(Icons.more_horiz),
        label: labels[3],
      ),
    ];
  }
}
