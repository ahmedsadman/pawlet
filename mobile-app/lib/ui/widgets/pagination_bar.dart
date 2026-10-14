import 'package:flutter/material.dart';

/// "Page X of Y" between previous/next chevrons. [page] is 1-based.
class PaginationBar extends StatelessWidget {
  const PaginationBar({
    required this.page,
    required this.totalPages,
    required this.onChange,
    super.key,
  });

  final int page;
  final int totalPages;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: page > 1 ? () => onChange(page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('Page $page of $totalPages', style: theme.textTheme.bodyMedium),
          IconButton(
            onPressed: page < totalPages ? () => onChange(page + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
