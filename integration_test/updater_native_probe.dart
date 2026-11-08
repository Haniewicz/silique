// Manual native-installer probe for an isolated disposable Android emulator.
// Build this entry point only for testing. It never opens notes or the key store.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:silique/storage/native_updates.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Probe());
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  static const channel = MethodChannel('silique.notes/updates');
  String status = 'Gotowy';
  Future<void> run(bool allowed) async {
    try {
      final info = await channel.invokeMethod<Object>('info');
      // The real directory the Flutter updater hands to the downloader, so the
      // probe proves the <cacheDir>/silique-updates contract SiliqueUpdates.kt
      // and update_paths.xml rely on instead of a hardcoded path.
      final directory = await NativeUpdateInstaller().downloadDirectory();
      final path = allowed
          ? '$directory/Silique-10.apk'
          : '/sdcard/not-an-update.apk';
      final result = await channel.invokeMethod<String>('installAndroid', path);
      if (mounted) setState(() => status = '$info: $result');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(status),
            TextButton(
              onPressed: () => run(false),
              child: const Text('Test odrzucenia ścieżki'),
            ),
            TextButton(
              onPressed: () => run(true),
              child: const Text('Test instalatora'),
            ),
          ],
        ),
      ),
    ),
  );
}
