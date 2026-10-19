import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  print('[demo] main() entrypoint reached');
  runApp(const DemoApp());
}

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> with WidgetsBindingObserver {
  bool _shouldExit = false;
  int _clicks = 0;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      print('[demo] text: "${_controller.text}"');
    });
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  bool _handleKey(KeyEvent event) {
    final String char = event.character == null ? '' : ' char=${event.character}';
    print('[demo] key: ${event.logicalKey.keyLabel}$char');
    return false;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    print('[demo] clipboard set: "${_controller.text}"');
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    print('[demo] clipboard get: "${data?.text}"');
    if (data?.text != null) {
      _controller.text = data!.text!;
    }
  }

  Future<void> _hasStrings() async {
    print('[demo] clipboard hasStrings: ${await Clipboard.hasStrings()}');
  }

  Future<void> _quit() async {
    final AppExitType exitType = _shouldExit ? AppExitType.required : AppExitType.cancelable;
    print('[demo] quit app');
    final response = await ServicesBinding.instance.exitApplication(exitType);
    print('[demo] quit app response $response');
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    print("[demo] request app exit");
    return AppExitResponse.exit;
  }

  void _radioChanged(bool? value) {
    value ??= true;
    if (_shouldExit == value) {
      return;
    }
    setState(() {
      _shouldExit = value!;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF223355),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                const Text(
                  'fembed',
                  style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                ),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  decoration: const InputDecoration(
                    hintText: 'type here...',
                    hintStyle: TextStyle(color: Colors.white38),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                    ),
                  ),
                ),
                Text(
                  'clicks: $_clicks',
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() => _clicks++);
                    print('[demo] tap $_clicks');
                  },
                  child: const Text('Click me'),
                ),
                RadioGroup<bool>(
                  groupValue: _shouldExit,
                  onChanged: (bool? value) => _radioChanged(value),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: <Widget>[
                      const RadioListTile<bool>(
                        title: Text('Do Not Allow Exit', style: TextStyle(color: Colors.white70)),
                        value: false,
                      ),
                      const RadioListTile<bool>(
                        title: Text('Allow Exit', style: TextStyle(color: Colors.white70)),
                        value: true,
                      ),
                      ElevatedButton(onPressed: _quit, child: const Text('Quit')),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    ElevatedButton(onPressed: _copy, child: const Text('Copy')),
                    ElevatedButton(onPressed: _paste, child: const Text('Paste')),
                    ElevatedButton(onPressed: _hasStrings, child: const Text('Has strings')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
