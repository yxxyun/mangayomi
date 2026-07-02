import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_manager.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_file.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

class CloudFileBrowserScreen extends ConsumerStatefulWidget {
  final CloudDriveType driveType;
  const CloudFileBrowserScreen({required this.driveType, super.key});

  @override
  ConsumerState<CloudFileBrowserScreen> createState() =>
      _CloudFileBrowserScreenState();
}

class _CloudFileBrowserScreenState extends ConsumerState<CloudFileBrowserScreen> {
  final _urlController = TextEditingController();
  List<CloudDriveFile> _files = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    final l10n = l10nLocalizations(context)!;
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = l10n.cloud_drive_enter_share_link(widget.driveType.displayName));
      return;
    }

    // Verify the URL matches the selected drive type
    final detectedType = CloudDriveManager.detectType(url);
    if (detectedType == null) {
      setState(() => _error = l10n.cloud_drive_unrecognized_link);
      return;
    }
    if (detectedType != widget.driveType) {
      setState(() => _error = l10n.cloud_drive_link_type_mismatch(widget.driveType.displayName));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _files = [];
    });

    try {
      final files = await CloudDriveManager.instance.getFilesFromUrl(url);
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
          if (files.isEmpty) {
            _error = l10n.cloud_drive_no_files_found;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = l10n.cloud_drive_load_failed;
        });
      }
    }
  }

  void _onFileTap(CloudDriveFile file) {
    final l10n = l10nLocalizations(context)!;
    if (file.isDir) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloud_drive_folder_browsing_coming_soon(file.name))),
      );
      return;
    }

    final videoExtensions = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm'];
    final extension = file.name.split('.').lastOrNull?.toLowerCase();
    final isVideo = extension != null && videoExtensions.contains('.$extension');

    if (!isVideo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloud_drive_unsupported_file_type(file.name))),
      );
      return;
    }

    // Get videos from cloud drive service
    _playVideoFile(file);
  }

  Future<void> _playVideoFile(CloudDriveFile file) async {
    final l10n = l10nLocalizations(context)!;
    final service = CloudDriveManager.instance.get(widget.driveType);
    if (service == null) return;

    final videoUrl = file.getEpisodeUrl('movie');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('${l10n.cloud_drive_loading_video}\n${file.name}', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final videos = await service.getVideos(videoUrl);
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading

      if (videos.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_cannot_get_video)),
          );
        }
        return;
      }

      _showVideoOptions(videos, file.name);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloud_drive_video_load_failed)),
      );
    }
  }

  void _showVideoOptions(List<Video> videos, String fileName) {
    final l10n = l10nLocalizations(context)!;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(fileName, style: Theme.of(context).textTheme.titleMedium),
          ),
          const Divider(),
          if (videos.length > 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l10n.cloud_drive_select_quality, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
            ),
          ],
          ...videos.map((video) => ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: Text(video.quality.isNotEmpty ? video.quality : l10n.cloud_drive_default_quality),
            subtitle: video.url.isNotEmpty ? Text(video.url,
              maxLines: 1, overflow: TextOverflow.ellipsis) : null,
            trailing: const Icon(Icons.open_in_new),
            onTap: () {
              Navigator.pop(ctx);
              _openVideoUrl(video.url, fileName);
            },
          )),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _openVideoUrl(String url, String fileName) {
    final l10n = l10nLocalizations(context)!;
    // Show URL with copy action
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.cloud_drive_video_url_label),
            const SizedBox(height: 8),
            SelectableText(url, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.cloud_drive_url_copied)),
              );
            },
            child: Text(l10n.cloud_drive_copy_link),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cloud_drive_file_browser_title(widget.driveType.displayName)),
      ),
      body: Column(
        children: [
          // URL input section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.themeData.cardColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.cloud_drive_share_link,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.secondaryColor,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          hintText: l10n.cloud_drive_enter_share_link(widget.driveType.displayName),
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: context.secondaryColor.withValues(alpha: 0.5),
                          ),
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 14),
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => _loadFiles(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _loading ? null : _loadFiles,
                      icon: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search),
                      label: Text(_loading ? l10n.cloud_drive_loading : l10n.cloud_drive_load),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Error message
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

          // File count / info bar
          if (_files.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.folder_open, size: 16, color: context.secondaryColor),
                  const SizedBox(width: 6),
                  Text(
                    l10n.cloud_drive_total_files(_files.length.toString()),
                    style: TextStyle(
                      fontSize: 13,
                      color: context.secondaryColor,
                    ),
                  ),
                ],
              ),
            ),

          // File list
          Expanded(
            child: _loading && _files.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _files.isEmpty && _error == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.cloud_outlined,
                              size: 64,
                              color: context.secondaryColor.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              l10n.cloud_drive_not_loaded_hint,
                              style: TextStyle(
                                fontSize: 14,
                                color: context.secondaryColor,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadFiles,
                        child: ListView.separated(
                          itemCount: _files.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final file = _files[index];
                            return _buildFileTile(file);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileTile(CloudDriveFile file) {
    final l10n = context.l10n;
    final isVideo = _isVideoFile(file.name);
    final sizeStr = _formatSize(file.size);

    return ListTile(
      leading: SizedBox(
        height: 40,
        child: Icon(
          file.isDir
              ? Icons.folder
              : isVideo
                  ? Icons.videocam
                  : Icons.insert_drive_file,
          color: file.isDir
              ? Colors.amber
              : isVideo
                  ? Colors.blue
                  : context.secondaryColor,
        ),
      ),
      title: Text(
        file.name,
        style: const TextStyle(fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          if (sizeStr != null) ...[
            Text(
              sizeStr,
              style: TextStyle(
                fontSize: 11,
                color: context.secondaryColor,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: file.isDir
                  ? Colors.amber.withValues(alpha: 0.1)
                  : isVideo
                      ? Colors.blue.withValues(alpha: 0.1)
                      : context.secondaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              file.isDir ? l10n.cloud_drive_folder : isVideo ? l10n.cloud_drive_video : l10n.cloud_drive_file_type,
              style: TextStyle(
                fontSize: 10,
                color: file.isDir
                    ? Colors.amber.shade700
                    : isVideo
                        ? Colors.blue
                        : context.secondaryColor,
              ),
            ),
          ),
        ],
      ),
      onTap: () => _onFileTap(file),
    );
  }

  bool _isVideoFile(String name) {
    final videoExtensions = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm'];
    final parts = name.split('.');
    if (parts.length < 2) return false;
    final ext = parts.last.toLowerCase();
    return videoExtensions.contains(ext);
  }

  String? _formatSize(String? size) {
    if (size == null || size.isEmpty || size == '0') return null;
    final bytes = int.tryParse(size);
    if (bytes == null) return size;
    return CloudDriveFile.getHumanReadableSize(bytes);
  }
}
