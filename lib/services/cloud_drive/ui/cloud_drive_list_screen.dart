import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/services/cloud_drive/auth/cookie_manager.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_account.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/services/cloud_drive/ui/cloud_drive_detail_screen.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

class CloudDriveListScreen extends ConsumerStatefulWidget {
  const CloudDriveListScreen({super.key});

  @override
  ConsumerState<CloudDriveListScreen> createState() =>
      _CloudDriveListScreenState();
}

class _CloudDriveListScreenState extends ConsumerState<CloudDriveListScreen> {
  Map<CloudDriveType, CloudDriveAccount?> _accounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    setState(() => _loading = true);
    final accounts = <CloudDriveType, CloudDriveAccount?>{};
    for (final type in CloudDriveType.values) {
      accounts[type] = await CloudCookieManager.getAccount(type);
    }
    if (mounted) {
      setState(() {
        _accounts = accounts;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘管理')),
      body: RefreshIndicator(
        onRefresh: _loadAccounts,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                itemCount: CloudDriveType.values.length,
                itemBuilder: (context, index) {
                  final type = CloudDriveType.values[index];
                  final account = _accounts[type];
                  return _buildDriveTile(type, account);
                },
              ),
      ),
    );
  }

  Widget _buildDriveTile(CloudDriveType type, CloudDriveAccount? account) {
    final isLoggedIn = account?.isLoggedIn ?? false;
    final isExpired = account?.isExpired ?? false;

    String statusText;
    Color statusColor;
    IconData statusIcon;
    if (!isLoggedIn) {
      statusText = '未登录';
      statusColor = context.secondaryColor;
      statusIcon = Icons.logout;
    } else if (isExpired) {
      statusText = '已过期';
      statusColor = Colors.orange;
      statusIcon = Icons.warning_amber_rounded;
    } else {
      statusText = '已登录';
      statusColor = Colors.green;
      statusIcon = Icons.check_circle_outline;
    }

    return ListTile(
      leading: SizedBox(
        height: 40,
        child: Icon(type.icon, color: context.primaryColor),
      ),
      title: Text(type.displayName),
      subtitle: Row(
        children: [
          Icon(statusIcon, size: 12, color: statusColor),
          const SizedBox(width: 4),
          Text(
            statusText,
            style: TextStyle(fontSize: 11, color: statusColor),
          ),
        ],
      ),
      trailing: isLoggedIn && !isExpired
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '已登录',
                style: TextStyle(fontSize: 12, color: Colors.green),
              ),
            )
          : Icon(Icons.chevron_right, color: context.secondaryColor),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CloudDriveDetailScreen(driveType: type),
          ),
        );
        if (mounted) {
          _loadAccounts();
        }
      },
    );
  }
}
