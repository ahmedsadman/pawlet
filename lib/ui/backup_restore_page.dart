import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_service.dart';
import '../state/finance_providers.dart';
import '../state/messages_providers.dart';
import '../state/providers.dart';

/// Export all local data to a JSON file (shared via the Android share sheet) or
/// restore it from a picked file (replace-all, after a confirmation). PIN and
/// API key are never included.
class BackupRestorePage extends ConsumerStatefulWidget {
  const BackupRestorePage({super.key});

  @override
  ConsumerState<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends ConsumerState<BackupRestorePage> {
  bool _busy = false;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(backupServiceProvider).exportJson();
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/meowni-backup-$stamp.json');
      await file.writeAsString(json);
      try {
        await SharePlus.instance.share(
          ShareParams(
            subject: 'Meowni backup',
            files: [XFile(file.path, mimeType: 'application/json')],
          ),
        );
      } finally {
        // The share completes (or is dismissed) before this returns, so the
        // temp file — which holds user data — is safe to remove afterward.
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      _toast('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from backup?'),
        content: const Text(
          'This replaces all current data on this device with the contents of '
          'the backup file. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked.isEmpty) return; // user cancelled

    setState(() => _busy = true);
    try {
      final bytes = await picked.single.readAsBytes();
      await ref.read(backupServiceProvider).importJson(utf8.decode(bytes));
      // Refresh visible data now; advise a restart for settings-derived caches.
      refreshAllFinance(ref);
      ref.invalidate(queuedProvider);
      ref.invalidate(historyProvider);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore complete'),
          content: const Text(
            'Your data has been restored. Restart Meowni to make sure every '
            'screen reflects the change.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on BackupFormatException catch (e) {
      _toast('Invalid backup file: ${e.message}');
    } catch (e) {
      _toast('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Save all your banks, messages, transactions, bills and settings to '
            'a JSON file, or restore them from one. Your PIN and API key are not '
            'included.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _backup,
            icon: const Icon(Icons.upload_file),
            label: const Text('Back up to file'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.download),
            label: const Text('Restore from file'),
          ),
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
