import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../models/finance/transaction.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';

/// Opens the "add manual transaction" bottom sheet. Resolves to `true` when a
/// transaction was added (so the caller can refresh), otherwise null.
Future<bool?> showAddTransactionSheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _AddTransactionSheet(),
  );
}

/// Manual transaction form rendered inside a bottom sheet. The user picks a
/// bank, enters an amount, chooses Income/Expense, and picks a date (default
/// now). Manual entries are Income/Expense only and have no backing SMS.
class _AddTransactionSheet extends ConsumerStatefulWidget {
  const _AddTransactionSheet();

  @override
  ConsumerState<_AddTransactionSheet> createState() =>
      _AddTransactionSheetState();
}

class _AddTransactionSheetState extends ConsumerState<_AddTransactionSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  int? _bankId;
  TxType _type = TxType.expense;
  late DateTime _date;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      // Preserve the time-of-day so intra-day ordering stays stable.
      setState(
        () => _date = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _date.hour,
          _date.minute,
        ),
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _bankId == null) return;
    setState(() => _saving = true);
    final currency = ref.read(currencyProvider).value?.data ?? 'BDT';
    await ref
        .read(financeRepositoryProvider)
        .insertManualTransaction(
          bankId: _bankId!,
          amount: _amount.text.trim(),
          type: _type,
          date: _date,
          currency: currency,
        );
    if (!mounted) return;
    refreshAllFinance(ref);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banksAsync = ref.watch(banksProvider);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: banksAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to load banks: $e'),
          ),
          data: (result) {
            final banks = result.data;
            if (banks.isEmpty) return _emptyBanks(theme);
            return _form(theme, banks);
          },
        ),
      ),
    );
  }

  Widget _form(ThemeData theme, List<Bank> banks) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add transaction', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _bankId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Bank',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final Bank b in banks)
                DropdownMenuItem(value: b.id, child: Text(b.name)),
            ],
            onChanged: (v) => setState(() => _bankId = v),
            validator: (v) => v == null ? 'Please select a bank' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Amount',
              border: OutlineInputBorder(),
              hintText: 'e.g. 500.00',
            ),
            validator: (v) {
              final t = (v ?? '').trim();
              final value = double.tryParse(t);
              if (value == null || value <= 0) return 'Enter a valid amount';
              return null;
            },
          ),
          const SizedBox(height: 16),
          SegmentedButton<TxType>(
            segments: const [
              ButtonSegment(value: TxType.income, label: Text('Income')),
              ButtonSegment(value: TxType.expense, label: Text('Expense')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 16),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Date',
              border: OutlineInputBorder(),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmtDate(_date), style: theme.textTheme.bodyLarge),
                TextButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: const Text('Change'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.add),
              label: const Text('Add transaction'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyBanks(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_balance_outlined,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Add a bank first',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Manual transactions are attached to a bank. Add one from '
            'Banks & Cards, then come back.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
