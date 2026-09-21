import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/permissions.dart';
import '../state/finance_providers.dart';
import '../state/providers.dart';
import 'banks_page.dart';

/// Settings tab: AI (OpenRouter) key + model, normalized currency, bank
/// management, contact-name resolution, and background-delivery help.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _currency;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late bool _resolveContacts;
  bool _obscureKey = true;
  String? _version;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsRepositoryProvider);
    _currency = TextEditingController(text: settings.currency);
    _model = TextEditingController(text: settings.llmModel);
    _apiKey = TextEditingController(text: ref.read(apiKeyProvider));
    _resolveContacts = settings.resolveContacts;
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

  @override
  void dispose() {
    _currency.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveAi() async {
    await ref.read(apiKeyProvider.notifier).set(_apiKey.text);
    await ref.read(settingsRepositoryProvider).setLlmModel(_model.text);
    // Rebuild the pipeline so the new model takes effect (the key already
    // rebuilds it via apiKeyProvider).
    ref.invalidate(appServicesProvider);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    _toast('AI settings saved');
  }

  Future<void> _saveCurrency() async {
    await ref.read(settingsRepositoryProvider).setCurrency(_currency.text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    refreshAllFinance(ref);
    _toast('Currency saved');
  }

  Future<void> _setResolveContacts(bool value) async {
    await ref.read(settingsRepositoryProvider).setResolveContacts(value);
    setState(() => _resolveContacts = value);
  }

  Future<void> _requestBattery() async {
    final granted = await AppPermissions.requestBatteryExemption();
    if (!mounted) return;
    _toast(
      granted
          ? 'Battery optimization disabled for Meowni'
          : 'Permission not granted',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('AI (OpenRouter)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKey,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key',
              hintText: 'sk-or-...',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureKey ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _model,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Model',
              hintText: 'openrouter/free',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Meowni sends only the SMS text to OpenRouter to classify and extract '
            'transactions. Get a free key at openrouter.ai. The free-models '
            'router (openrouter/free) is a good default.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saveAi,
              icon: const Icon(Icons.save),
              label: const Text('Save'),
            ),
          ),
          const Divider(height: 32),
          Text('Currency', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _currency,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Normalized currency',
                    hintText: 'e.g. BDT',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _saveCurrency,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ],
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance_outlined),
            title: const Text('Manage banks'),
            subtitle: const Text('Add, edit or remove banks and credit cards'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BanksPage())),
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Resolve contact names'),
            subtitle: const Text(
              'Show your saved contact name for numeric senders. Requires '
              'Contacts permission.',
            ),
            value: _resolveContacts,
            onChanged: _setResolveContacts,
          ),
          const Divider(height: 32),
          Text('Background delivery', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Disable battery optimization so Meowni can keep processing messages '
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
