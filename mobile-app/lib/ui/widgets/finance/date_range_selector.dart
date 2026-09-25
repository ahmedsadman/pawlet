import 'package:flutter/material.dart';

import '../../../utils/date_range.dart';

/// A compact button that opens a bottom sheet of date-range presets.
class DateRangeSelector extends StatelessWidget {
  const DateRangeSelector({
    required this.value,
    required this.onSelected,
    super.key,
  });

  final DateRangePreset value;
  final ValueChanged<DateRangePreset> onSelected;

  Future<void> _open(BuildContext context) async {
    final selected = await showModalBottomSheet<DateRangePreset>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        // Scrollable so the full preset list (and the last item) is reachable
        // on short sheets instead of overflowing.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final preset in DateRangePreset.values)
                ListTile(
                  title: Text(preset.label),
                  trailing: preset == value
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(context).pop(preset),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && selected != value) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => _open(context),
      icon: const Icon(Icons.calendar_today_outlined, size: 16),
      label: Text(value.label),
    );
  }
}
