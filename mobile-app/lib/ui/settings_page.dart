import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/permissions.dart';
import '../state/auth_providers.dart';
import '../state/finance_providers.dart';
import '../state/providers.dart';
import 'backup_restore_page.dart';
import 'banks_page.dart';
import 'security/change_pin_screen.dart';

/// Settings tab: normalized currency, bank management, contact-name resolution,
/// background-delivery help, security, and a privacy note. The LLM key/model are
/// no longer configurable here — the key is provisioned via `--dart-define` and
/// stored encrypted (see SecureStore), and the model is hardcoded.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late String _currency;
  String? _version;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsRepositoryProvider);
    // Clamp to the two supported options so the SegmentedButton never asserts on
    // a legacy free-text currency.
    final stored = settings.currency;
    _currency = stored == 'USD' ? 'USD' : 'BDT';
    // Normalize a legacy free-text value (e.g. from the old text field) so the
    // stored currency matches the toggle the user sees — otherwise finance
    // amounts would keep rendering against the stale currency until first tap.
    if (stored != 'BDT' && stored != 'USD') {
      settings.setCurrency(_currency);
    }
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

  Future<void> _setCurrency(String value) async {
    setState(() => _currency = value);
    await ref.read(settingsRepositoryProvider).setCurrency(value);
    refreshAllFinance(ref);
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

  Future<void> _setBiometric(bool value) async {
    final ok = await ref
        .read(authControllerProvider.notifier)
        .setBiometricEnabled(value);
    if (!mounted) return;
    if (!ok && value) _toast('Biometric verification failed');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Currency', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'All amounts are normalized to this currency.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'BDT', label: Text('BDT')),
              ButtonSegment(value: 'USD', label: Text('USD')),
            ],
            selected: {_currency},
            onSelectionChanged: (s) => _setCurrency(s.first),
          ),
          const Divider(height: 32),
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
          const Divider(height: 32),
          Text('Privacy', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Everything Pawlet knows stays on this device — nothing is uploaded '
            'or synced. To read a message we send only its text for one-time '
            'metadata extraction, with no name, number, or identifying detail '
            'attached.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          if (_version != null) ...[
            const Divider(height: 32),
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
