import 'package:flutter/material.dart';

import 'car_mode_session.dart';

class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key, required this.session});
  final CarModeSession session;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}
