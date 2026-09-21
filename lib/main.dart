import 'package:flutter/material.dart';

import 'theme/catppuccin_theme.dart';

void main() {
  runApp(const MeowniApp());
}

class MeowniApp extends StatelessWidget {
  const MeowniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meowni',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const Scaffold(
        body: Center(child: Text('Meowni')),
      ),
    );
  }
}
