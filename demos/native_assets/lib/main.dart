import 'package:flutter/material.dart';
import 'package:native_sum/native_sum.dart';

void main() {
  runApp(const NativeAssetsApp());
}

class NativeAssetsApp extends StatelessWidget {
  const NativeAssetsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final sum = native_sum(20, 22);
    return MaterialApp(
      title: 'Native assets',
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Dart native assets'),
              const SizedBox(height: 12),
              Text(
                'native_sum(20, 22) = $sum',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
