import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/llm/llm_mode.dart';
import '../services/permissions.dart';
import '../services/privacy_policy.dart';
import '../state/auth_providers.dart';
import '../state/providers.dart';
import 'app_update_flow.dart';
import 'backup_restore_page.dart';
import 'banks_page.dart';
import 'bulk_import_flow.dart';
import 'privacy/sms_access_flow.dart';
import 'security/change_pin_screen.dart';
import 'settings/byok_section.dart';

/// Settings tab: bank management, background-delivery help, security, and
/// privacy. The privacy copy and the key input both follow the resolved
/// [LlmMode].
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(
        () => _version = 'Version ${info.version} (build ${info.buildNumber})',
      );
    } catch (_) {
      // Version is informational; ignore if unavailable.
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openPrivacyPolicy() async {
    final opened = await PrivacyPolicy.open();
    if (!mounted || opened) return;
    _toast('Could not open your browser');
  }

  Future<void> _requestBattery() async {
    final granted = await AppPermissions.requestBatteryExemption();
    if (!mounted) return;
    _toast(
      granted
          ? 'Battery optimization disabled for Pawlet'
          : 'Permission not granted',
    );
  }

  Future<void> _importInbox() async {
    if (!await ensureSmsAccess(context)) {
      if (!mounted) return;
      _toast('SMS permission is required to read your inbox');
      return;
    }
    if (!mounted) return;
    final accepted = await confirmBulkImport(context);
    if (!accepted || !mounted) return;
    await runBulkImport(context, ref);
  }

  Future<void> _setBiometric(bool value) async {
    final ok = await ref
        .read(authControllerProvider.notifier)
        .setBiometricEnabled(value);
    if (!mounted) return;
    if (!ok && value) _toast('Biometric verification failed');
  }

  static String _privacyCopy(LlmMode mode) {
    // The three modes differ in where a message can go, so one paragraph would
    // be wrong for two of them.
    return switch (mode) {
      LlmMode.proxy =>
        'All data stays on device. Messages the local classification model '
            "can't categorize may be sent to Pawlet's service to be classified, "
            'where they are never stored or logged. No identifying information is '
            'recorded externally.',
      LlmMode.byok =>
        'All data stays on device. Messages the on-device model cannot categorize '
            'are sent to OpenRouter using your own API key. '
            "Pawlet's own service is not involved.",
      LlmMode.none =>
        'Your messages never leave your phone. The on-device model is the only '
            'classifier, and a message it cannot read is marked failed in Messages, '
            'where you can retry it later.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = ref.watch(llmModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance_outlined),
            title: const Text('Manage Banks & Cards'),
            subtitle: const Text('Add, edit or remove banks and credit cards'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BanksPage())),
          ),
          const Divider(height: 32),
          Text('Data', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backup & Restore'),
            subtitle: const Text(
              'Export or import all your data as a JSON file',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BackupRestorePage()),
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('Import existing messages'),
            subtitle: const Text(
              'Scan your SMS inbox and create records with the on-device model',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _importInbox,
          ),
          const Divider(height: 32),
          Text('Background delivery', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Disable battery optimization so Pawlet can keep processing messages '
            'in the background.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _requestBattery,
            icon: const Icon(Icons.battery_saver),
            label: const Text('Disable battery optimization'),
          ),
          const Divider(height: 32),
          Text('Security', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Change PIN'),
            subtitle: const Text('Update your 4-digit app PIN'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ChangePinScreen())),
          ),
          if (ref.watch(authControllerProvider).biometricAvailable)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Unlock with biometrics'),
              subtitle: const Text(
                'Use your fingerprint or face to unlock the app.',
              ),
              value: ref.watch(authControllerProvider).biometricEnabled,
              onChanged: _setBiometric,
            ),
          if (mode.showsByokSection) ...[
            const Divider(height: 32),
            const ByokSection(),
          ],
          const Divider(height: 32),
          Text('Privacy', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _privacyCopy(mode),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            subtitle: const Text('Opens in your browser'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: _openPrivacyPolicy,
          ),
          const Divider(height: 32),
          // Play rejects update checks from installs it did not deliver.
          if (ref.watch(settingsRepositoryProvider).installedFromPlay)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_alt_rounded),
              title: const Text('Check for updates'),
              subtitle: const Text('Get the latest version from Google Play'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => runAppUpdateCheck(context, ref, manual: true),
            ),
          if (_version != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                _version!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
