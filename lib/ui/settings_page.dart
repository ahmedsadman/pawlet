import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/finance_providers.dart';
import '../state/providers.dart';
import 'banks_page.dart';

/// Settings tab. Phase 2 covers the normalized currency and bank management;
/// the LLM API key / model and security options are added in a later phase.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _currency;

  @override
  void initState() {
    super.initState();
    _currency = TextEditingController(
      text: ref.read(settingsRepositoryProvider).currency,
    );
  }

  @override
  void dispose() {
    _currency.dispose();
    super.dispose();
  }

  Future<void> _saveCurrency() async {
    await ref.read(settingsRepositoryProvider).setCurrency(_currency.text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    refreshAllFinance(ref);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Currency saved')));
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
        ],
      ),
    );
  }
}
