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

class _DemoAppState extends State<DemoApp> {
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
              children: [
                const Text(
                  'fembed',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
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
                const SizedBox(height: 20),
                Text(
                  'clicks: $_clicks',
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () {
                    setState(() => _clicks++);
                    print('[demo] tap $_clicks');
                  },
                  child: const Text('Click me'),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    ElevatedButton(
                      onPressed: _copy,
                      child: const Text('Copy'),
                    ),
                    ElevatedButton(
                      onPressed: _paste,
                      child: const Text('Paste'),
                    ),
                    ElevatedButton(
                      onPressed: _hasStrings,
                      child: const Text('Has strings'),
                    ),
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
