import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/llm/key_validator.dart';
import '../../state/providers.dart';
import '../../theme/catppuccin_theme.dart';

/// Bring-your-own-key input for OpenRouter, shown in Settings when the user is
/// in `LlmMode.byok` or `LlmMode.none`. A proxy install already has an LLM, so
/// the section is hidden there.
class ByokSection extends ConsumerStatefulWidget {
  const ByokSection({super.key});

  @override
  ConsumerState<ByokSection> createState() => _ByokSectionState();
}

class _ByokSectionState extends ConsumerState<ByokSection> {
  final _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final entered = _controller.text.trim();
    if (entered.isEmpty) {
      setState(() => _error = 'Enter a key first');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final result = await ref.read(keyValidatorProvider).check(entered);
      if (!mounted) return;

      switch (result) {
        case KeyCheck.valid:
          try {
            await ref.read(apiKeyProvider.notifier).save(entered);
            if (!mounted) return;
            setState(() {
              _controller.clear();
              _error = null;
            });
          } catch (_) {
            if (!mounted) return;
            setState(() => _error = "Couldn't save the key");
          }
        case KeyCheck.invalid:
          if (!mounted) return;
          setState(() => _error = 'Invalid key');
        case KeyCheck.unreachable:
          if (!mounted) return;
          setState(() => _error = "Couldn't reach OpenRouter");
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _onRemove() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiKeyProvider.notifier).clear();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = ref.watch(apiKeyProvider).isNotEmpty;
    final ineligible = ref.watch(attestationIneligibleProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 32),
        const Divider(height: 1),
        const SizedBox(height: 32),
        Text('Use LLM to improve accuracy', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          'The on-device model handles most messages, but you can add a personal '
          'OpenRouter API key for better accuracy on tricky ones. The models '
          'Pawlet uses are free. Get your key at openrouter.ai/keys.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        if (ineligible) ...[
          const SizedBox(height: 8),
          Text(
            "This device didn't pass Google's integrity check, so Pawlet's own "
            'service cannot be used here. A personal key restores LLM parsing.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.flavor.peach,
            ),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          enabled: !_saving,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: 'sk-or-...',
            labelText: hasKey ? 'Replace key' : 'OpenRouter API key',
            errorText: _error,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: _saving ? null : _onSave,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            if (hasKey) ...[
              const SizedBox(width: 12),
              TextButton(
                onPressed: _saving ? null : _onRemove,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.flavor.red,
                ),
                child: const Text('Remove key'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
