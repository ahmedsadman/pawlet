import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../models/finance/transaction.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../utils/time_format.dart';
import '../keyboard_inset.dart';

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
/// bank, enters an amount, chooses Income/Expense/Transfer, and picks a date
/// (default now). Manual entries have no backing SMS.
class _AddTransactionSheet extends ConsumerStatefulWidget {
  const _AddTransactionSheet();

  @override
  ConsumerState<_AddTransactionSheet> createState() =>
      _AddTransactionSheetState();
}

class _AddTransactionSheetState extends ConsumerState<_AddTransactionSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _amountFocus = FocusNode();
  int? _bankId;
  String? _bankError;
  TxType _type = TxType.expense;
  late DateTime _date;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
    // Defer raising the keyboard until the open animation has settled. Focusing
    // during the slide-in (with isScrollControlled) forces the sheet to
    // re-layout for the growing keyboard inset every frame, which janks the
    // open. Waiting past the sheet's enter duration keeps the open smooth.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _amountFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    super.dispose();
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

  /// Opens a bank picker as its own bottom sheet. Dismissing the keyboard first
  /// (and using a bottom-anchored sheet rather than a field-anchored dropdown
  /// overlay) avoids the "zombie" menu that floated where the field used to be
  /// before the keyboard-hide collapsed this sheet.
  Future<void> _pickBank(List<Bank> banks) async {
    FocusScope.of(context).unfocus();
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final b in banks)
                ListTile(
                  title: Text(b.name),
                  trailing: b.id == _bankId
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(context).pop(b.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _bankId = picked;
        _bankError = null;
      });
    }
  }

  Future<void> _save() async {
    final amountOk = _formKey.currentState!.validate();
    if (_bankId == null) setState(() => _bankError = 'Please select a bank');
    if (!amountOk || _bankId == null) return;
    setState(() => _saving = true);
    final currency = ref.read(currencyProvider).value?.data ?? 'BDT';
    try {
      await ref
          .read(financeRepositoryProvider)
          .insertManualTransaction(
            bankId: _bankId!,
            amount: _amount.text.trim(),
            type: _type,
            date: _date,
            currency: currency,
          );
    } catch (e) {
      // Re-enable the form and surface the failure; keep the sheet open so the
      // user can retry without losing their input.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not add transaction: $e')));
      return;
    }
    if (!mounted) return;
    refreshAllFinance(ref);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banksAsync = ref.watch(banksProvider);

    // NOTE: this build must NOT read MediaQuery.viewInsets — the keyboard inset
    // is applied by the leaf [KeyboardInset] so only that tiny widget rebuilds
    // per IME-animation frame, not the whole form (which caused show/hide jank).
    return SafeArea(
      // Bottom handled by KeyboardInset (max of IME + nav-bar) to keep the pad
      // monotonic through the keyboard animation.
      bottom: false,
      child: KeyboardInset(
        child: Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: 16,
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
      ),
    );
  }

  Widget _form(ThemeData theme, List<Bank> banks) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add transaction', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            // Tap-to-open bank picker (a bottom sheet, not a field-anchored
            // dropdown) so dismissing the keyboard can't leave a floating menu.
            InkWell(
              onTap: () => _pickBank(banks),
              borderRadius: BorderRadius.circular(4),
              child: InputDecorator(
                isEmpty: _bankId == null,
                decoration: InputDecoration(
                  labelText: 'Select Bank',
                  border: const OutlineInputBorder(),
                  errorText: _bankError,
                  suffixIcon: const Icon(Icons.arrow_drop_down),
                ),
                child: _bankId == null
                    ? null
                    : Text(
                        banks.firstWhere((b) => b.id == _bankId).name,
                        style: theme.textTheme.bodyLarge,
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _amount,
              focusNode: _amountFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                // Digits with at most one decimal point (rejects e.g. "5.0.0").
                TextInputFormatter.withFunction((oldValue, newValue) {
                  final t = newValue.text;
                  if (t.isEmpty || RegExp(r'^\d*\.?\d*$').hasMatch(t)) {
                    return newValue;
                  }
                  return oldValue;
                }),
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
                ButtonSegment(value: TxType.transfer, label: Text('Transfer')),
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
                  Text(dateLabel(_date), style: theme.textTheme.bodyLarge),
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
