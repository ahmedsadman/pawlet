import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/bank_catalog.dart';
import '../models/finance/bank.dart';
import '../state/finance_providers.dart';
import '../state/providers.dart';
import '../theme/catppuccin_theme.dart';

/// Bank management: list, add, edit and delete the accounts whose SMS Meowni
/// watches. Built from the same components/theme as the Finance tab.
class BanksPage extends ConsumerWidget {
  const BanksPage({super.key});

  Future<void> _openForm(BuildContext context, WidgetRef ref, {Bank? bank}) async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => BankFormPage(bank: bank)));
    if (saved == true) refreshAllFinance(ref);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Bank bank,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete bank?'),
        content: Text(
          'Remove "${bank.name}"? Its transactions and bills stay, but new SMS '
          'from it will no longer be recognized.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(banksRepositoryProvider).delete(bank.id);
    refreshAllFinance(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banksAsync = ref.watch(banksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Banks & Cards')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(context, ref),
        child: const Icon(Icons.add),
      ),
      body: banksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load banks: $e')),
        data: (result) {
          final banks = result.data;
          if (banks.isEmpty) {
            return const _EmptyBanks();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: banks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final bank = banks[i];
              return _BankTile(
                bank: bank,
                onTap: () => _openForm(context, ref, bank: bank),
                onDelete: () => _confirmDelete(context, ref, bank),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyBanks extends StatelessWidget {
  const _EmptyBanks();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.account_balance_outlined,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No banks yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a bank so Meowni can recognize its SMS.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BankTile extends StatelessWidget {
  const _BankTile({
    required this.bank,
    required this.onTap,
    required this.onDelete,
  });

  final Bank bank;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = bank.name.isNotEmpty ? bank.name[0].toUpperCase() : '?';
    final subtitle = bank.isCredit
        ? 'Credit card${bank.last4 != null ? ' •••• ${bank.last4}' : ''}'
        : 'Deposit${bank.lastBalance != null ? ' · ${bank.lastBalance}' : ''}';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.flavor.surface1,
        child: Text(initial, style: theme.textTheme.titleMedium),
      ),
      title: Text(bank.name),
      subtitle: Text(subtitle),
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}

/// Add/edit form for a bank. Name + alternate sender names drive SMS matching;
/// credit cards additionally capture card digits (required for bill matching).
class BankFormPage extends ConsumerStatefulWidget {
  const BankFormPage({this.bank, super.key});

  final Bank? bank;

  @override
  ConsumerState<BankFormPage> createState() => _BankFormPageState();
}

class _BankFormPageState extends ConsumerState<BankFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _first4;
  late final TextEditingController _last4;
  late final TextEditingController _balance;
  late String _accountType;
  String? _selectedBank;

  bool get _isEdit => widget.bank != null;

  @override
  void initState() {
    super.initState();
    final b = widget.bank;
    // Only preselect when the stored bank is a known catalog entry.
    _selectedBank = (b != null && bankCatalogByLabel(b.name) != null)
        ? b.name
        : null;
    final digits = b?.cardDigits?.split('|');
    _first4 = TextEditingController(
      text: (digits != null && digits.length == 2) ? digits[0] : '',
    );
    _last4 = TextEditingController(
      text: (digits != null && digits.length == 2) ? digits[1] : '',
    );
    _balance = TextEditingController(text: b?.lastBalance ?? '');
    _accountType = b?.accountType ?? 'deposit';
  }

  @override
  void dispose() {
    _first4.dispose();
    _last4.dispose();
    _balance.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = ref.read(banksRepositoryProvider);
    final isCredit = _accountType == 'credit';
    final cardDigits = isCredit
        ? '${_first4.text.trim()}|${_last4.text.trim()}'
        : null;
    final balanceText = _balance.text.trim();
    final hasBalance = !isCredit && balanceText.isNotEmpty;

    final label = _selectedBank!;
    // Credit cards route purely by card digits and must carry NO sender-matchers,
    // so a non-card SMS falls back to the same bank's deposit instead of matching
    // both and resolving as ambiguous.
    final matchers = isCredit
        ? const <String>[]
        : (bankCatalogByLabel(label)?.matchers ?? const []);

    try {
      if (_isEdit) {
        await repo.update(
          widget.bank!.id,
          name: label,
          accountType: _accountType,
          matchers: matchers,
          cardDigits: cardDigits,
          clearCardDigits: !isCredit,
          lastBalance: hasBalance ? balanceText : null,
          clearLastBalance: !hasBalance,
          lastBalanceAt: hasBalance
              ? DateTime.now().millisecondsSinceEpoch
              : null,
        );
      } else {
        await repo.create(
          name: label,
          accountType: _accountType,
          matchers: matchers,
          cardDigits: cardDigits,
          lastBalance: hasBalance ? balanceText : null,
          lastBalanceAt: hasBalance
              ? DateTime.now().millisecondsSinceEpoch
              : null,
        );
      }
    } catch (e) {
      if (!mounted) return;
      final duplicate = e.toString().toLowerCase().contains('unique');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            duplicate
                ? '"$label" is already added.'
                : 'Could not save bank. Please try again.',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String? _validate4(String? v) {
    final t = (v ?? '').trim();
    if (t.length != 4 || int.tryParse(t) == null) return '4 digits';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCredit = _accountType == 'credit';

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Bank' : 'Add Bank')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedBank,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Bank'),
              items: [
                for (final entry in kBankCatalog)
                  DropdownMenuItem(value: entry.label, child: Text(entry.label)),
              ],
              onChanged: (v) => setState(() => _selectedBank = v),
              validator: (v) => v == null ? 'Please select your bank' : null,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick your bank from the list — Meowni recognizes its SMS '
              'automatically, no sender names to type. Missing a bank? Let us '
              'know and it will be added.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'deposit', label: Text('Deposit')),
                ButtonSegment(value: 'credit', label: Text('Credit card')),
              ],
              selected: {_accountType},
              onSelectionChanged: (s) =>
                  setState(() => _accountType = s.first),
            ),
            if (isCredit) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _first4,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'First 4',
                        counterText: '',
                      ),
                      validator: _validate4,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _last4,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Last 4',
                        counterText: '',
                      ),
                      validator: _validate4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Card digits are required — a bill is only recorded when the SMS '
                'contains a matching card number.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _balance,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Current balance (optional)',
                  hintText: 'e.g. 2000.00',
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  return double.tryParse(t) == null ? 'Invalid amount' : null;
                },
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(_isEdit ? 'Save changes' : 'Add bank'),
            ),
          ],
        ),
      ),
    );
  }
}
