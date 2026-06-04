import 'package:flutter/material.dart';
import 'ui/start_screen.dart';

void main() => runApp(const MoveArcadeApp());

class MoveArcadeApp extends StatelessWidget {
  const MoveArcadeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MoveArcade — Shadow Boxer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF2D78),
          brightness: Brightness.dark,
        ),
      ),
      home: const StartScreen(),
    );
  }
}
