import 'package:flutter/material.dart';
import '../games/shadow_boxer/shadow_boxer_screen.dart';

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});
  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  final _weight = TextEditingController(text: '70');

  void _start() {
    final w = double.tryParse(_weight.text)?.clamp(30, 200) ?? 70;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShadowBoxerScreen(weightKg: w.toDouble()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E14),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('MOVEARCADE',
                style: TextStyle(
                    color: Color(0xFFFF2D78), letterSpacing: 5, fontSize: 12)),
            const SizedBox(height: 12),
            const Text('Shadow Boxer',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 52,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 14),
            const SizedBox(
              width: 360,
              child: Text(
                'A pad lights up — punch it. Your real fists are the controller. '
                '60-second round. Pose runs on-device; nothing is uploaded.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8AA0B3), height: 1.6),
              ),
            ),
            const SizedBox(height: 28),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Your weight ',
                  style: TextStyle(color: Color(0xFF8AA0B3))),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _weight,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1F2B38))),
                  ),
                ),
              ),
              const Text('  kg', style: TextStyle(color: Color(0xFF8AA0B3))),
            ]),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF27D3A2),
                  foregroundColor: const Color(0xFF06090D),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 16)),
              onPressed: _start,
              child: const Text('Start round'),
            ),
          ]),
        ),
      ),
    );
  }
}
