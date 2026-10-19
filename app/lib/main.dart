import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

void main() {
  runApp(const KaTrainNeoApp());
}

class KaTrainNeoApp extends StatelessWidget {
  const KaTrainNeoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KaTrain Neo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E3A46), brightness: Brightness.dark),
      ),
      home: const Scaffold(body: Center(child: Text('KaTrain Neo $coreVersion — under construction'))),
    );
  }
}
