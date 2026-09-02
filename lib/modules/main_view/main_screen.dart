import 'dart:async';

import 'package:google_fonts/google_fonts.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:flutter/material.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/repositories/update_repository.dart';
import 'package:mangayomi/modules/more/about/providers/download_file_screen.dart';
import 'package:mangayomi/modules/widgets/error_state.dart';
import 'package:mangayomi/modules/widgets/loading_icon.dart';
import 'package:mangayomi/modules/main_view/providers/migration.dart';
import 'package:mangayomi/modules/main_view/providers/tv_mode_provider.dart';
import 'package:mangayomi/modules/more/about/providers/check_for_update.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/auto_backup.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
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

    // Pauses the auto-sync timer for the duration of a restore (and its
    // post-restore upload), instead of just rescheduling it — a restore can
    // outlast one sync interval, so a reschedule alone could still let the
    // timer fire mid-restore. syncServerProvider.startSync also checks this
    // guard directly, covering a manual sync trigger too.
    ref.listenManual<bool>(restoreSyncGuardProvider, (_, restoring) {
      if (restoring) {
        _syncTimer?.cancel();
        return;
      }
      // Re-read the live setting rather than the _autoSyncFrequency snapshot
      // taken at init — a restore can turn sync off (frequency reset to 0),
      // and that must take effect immediately, not just on next app launch.
      final freq = ref.read(synchingProvider(syncId: 1)).autoSyncFrequency;
      _syncTimer?.cancel();
      if (freq != 0) {
        _syncTimer = Timer.periodic(Duration(seconds: freq), _onSyncTimerTick);
      }
    });
    _initializeProviders();
  }

  void _initializeProviders() {
    // The extension-repo fetches (one per item type) and the GitHub update
    // check hit the network; delay them so they don't compete with the first
    // paint and the initial library queries.
    Future.delayed(const Duration(seconds: 3), () {
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
      // On TV the in-app updater (download + install an APK) is not reachable
      // with a d-pad and is not how TV builds update (sideload / the release
      // APK). Left on, this modal would appear unannounced over whatever the
      // user is doing and trap focus with no way to dismiss it.
      if (isTv) return;
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
    final incognitoMode = ref.watch(incognitoModeStateProvider);
    final l10n = context.l10n;
    return ref.watch(migrationProvider).when(
      data: (_) => Scaffold(
        body: Column(
          children: [
            _IncognitoModeBar(incognitoMode: incognitoMode, l10n: l10n),
            Expanded(
              child: context.isTablet ? _tabletLayout(shell) : shell,
            ),
          ],
        ),
        bottomNavigationBar:
            context.isTablet ? null : _mobileBottomNav(shell),
      ),
      // A failed migration used to render the loading screen, so the app
      // sat on a blank splash forever with nothing to act on. Show what
      // happened and let the user run it again.
      error: (error, _) => Scaffold(
        body: ErrorState(
          message: l10n.startup_failed,
          detail: error.toString(),
          onRetry: () => ref.invalidate(migrationProvider),
        ),
      ),
      loading: () => const LoadingIcon(),
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

class _IncognitoModeBar extends StatelessWidget {
  const _IncognitoModeBar({required this.incognitoMode, required this.l10n});

  final bool incognitoMode;
  final dynamic l10n;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: AnimatedContainer(
        height: incognitoMode
            ? isMobile
                  ? MediaQuery.of(context).padding.top * 2
                  : 50
            : 0,
        curve: Curves.easeIn,
        duration: const Duration(milliseconds: 150),
        color: context.primaryColor,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                l10n.incognito_mode,
                style: const TextStyle(
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
