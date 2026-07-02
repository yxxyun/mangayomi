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
  const MainScreen({super.key, required this.child});

  final Widget child;

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
    _syncTimer = Timer.periodic(
      Duration(
        seconds: ref.read(synchingProvider(syncId: 1)).autoSyncFrequency,
      ),
      (timer) => _onSyncTimerTick(timer),
    );
    // Warm up source lists
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

  bool get _isReadingScreen {
    final location = ref.watch(routerCurrentLocationStateProvider);
    return _readerRoutes.contains(location);
  }

  int _currentIndex(String? location) {
    final idx = _tabRoutes.indexOf(location ?? '/anime');
    return idx >= 0 ? idx : 0;
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

    if (_isReadingScreen) {
      return widget.child;
    }

    return Scaffold(
      body: context.isTablet ? _tabletLayout(location) : widget.child,
      bottomNavigationBar:
          context.isTablet ? null : _mobileBottomNav(location),
    );
  }

  Widget _tabletLayout(String? location) {
    final destinations = [
      NavigationRailDestination(
        icon: const Icon(Icons.video_collection_outlined),
        selectedIcon: const Icon(Icons.video_collection),
        label: const Text('Anime'),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.collections_bookmark_outlined),
        selectedIcon: const Icon(Icons.collections_bookmark),
        label: const Text('Manga'),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.local_library_outlined),
        selectedIcon: const Icon(Icons.local_library),
        label: const Text('Novel'),
      ),
      NavigationRailDestination(
        icon: const Icon(Icons.more_horiz_outlined),
        selectedIcon: const Icon(Icons.more_horiz),
        label: const Text('More'),
      ),
    ];

    return Row(
      children: [
        NavigationRail(
          labelType: NavigationRailLabelType.all,
          useIndicator: true,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          destinations: destinations,
          selectedIndex: _currentIndex(location),
          onDestinationSelected: (index) => context.go(_tabRoutes[index]),
        ),
        Expanded(child: widget.child),
      ],
    );
  }

  Widget _mobileBottomNav(String? location) {
    return NavigationBar(
      selectedIndex: _currentIndex(location),
      animationDuration: const Duration(milliseconds: 300),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
      ),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.video_collection_outlined),
          selectedIcon: Icon(Icons.video_collection),
          label: 'Anime',
        ),
        NavigationDestination(
          icon: Icon(Icons.collections_bookmark_outlined),
          selectedIcon: Icon(Icons.collections_bookmark),
          label: 'Manga',
        ),
        NavigationDestination(
          icon: Icon(Icons.local_library_outlined),
          selectedIcon: Icon(Icons.local_library),
          label: 'Novel',
        ),
        NavigationDestination(
          icon: Icon(Icons.more_horiz_outlined),
          selectedIcon: Icon(Icons.more_horiz),
          label: 'More',
        ),
      ],
      onDestinationSelected: (index) => context.go(_tabRoutes[index]),
    );
  }
}
