import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'strings.dart';
export 'strings.dart' show tr;

/// Native platform seam for tests; no binding or real host preferences required.
@visibleForTesting
Future<void> Function(String languageCode)? debugNativeLanguageWriter;

/// Device-local preference, independent of vaults, accounts and credentials.
class AppLanguageController extends ChangeNotifier {
  String _languageCode = 'en';
  bool _nativeSyncPending = false;
  File? _preference;
  Future<void> _pending = Future<void>.value();

  String get languageCode => _languageCode;
  Locale get locale => Locale(_languageCode);
  bool get nativeSyncPending => _nativeSyncPending;

  Future<void> initialize(Directory support) async {
    final file = File('${support.path}/interface-language');
    _preference = file;
    var code = 'en';
    try {
      if (await file.exists()) {
        // This tiny optional preference must never block notebook startup.
        if (await file.length() <= 16) {
          final saved = (await file.readAsString()).trim();
          if (saved == 'pl' || saved == 'en') code = saved;
        }
      }
    } on FileSystemException {
      // Preserve the unreadable file; an explicit selection can replace it.
    } on FormatException {
      // Decoders on other supported runtimes may expose malformed UTF-8 directly.
    }
    _languageCode = code;
    currentLanguageCode = code;
    await _synchronizeNativeLanguage();
    notifyListeners();
  }

  Future<void> setLanguage(String code) {
    if (code != 'en' && code != 'pl') {
      return Future<void>.error(ArgumentError.value(code, 'code'));
    }
    final operation = _pending.then((_) async {
      final file = _preference;
      if (file != null) {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.pending');
        await temporary.writeAsString(code, flush: true);
        await temporary.rename(file.path);
      }
      _languageCode = code;
      currentLanguageCode = code;
      notifyListeners();
      await _synchronizeNativeLanguage();
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> retryNativeSynchronization() {
    final operation = _pending.then((_) => _synchronizeNativeLanguage());
    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> _synchronizeNativeLanguage() async {
    try {
      await _updateNativeLanguage();
      _nativeSyncPending = false;
    } catch (_) {
      // The flushed device preference is authoritative. Resource/widget refresh
      // is presentation-only and must never prevent notebook initialization.
      _nativeSyncPending = true;
    }
    notifyListeners();
  }

  Future<void> _updateNativeLanguage() async {
    final override = debugNativeLanguageWriter;
    if (override != null) return override(_languageCode);
    if (!Platform.isAndroid && !Platform.isMacOS) return;
    await const MethodChannel('silique/language')
        .invokeMethod<void>('setLanguage', {'languageCode': _languageCode});
  }
}

class LanguageBuilder extends StatelessWidget {
  const LanguageBuilder({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => builder(context),
  );
}

final appLanguage = AppLanguageController();

/// Rebuilds localization delegates without replacing the navigator or notebook.
class SiliqueMaterialApp extends StatelessWidget {
  const SiliqueMaterialApp({
    super.key,
    this.title = '',
    this.debugShowCheckedModeBanner = false,
    this.theme,
    this.scaffoldMessengerKey,
    required this.home,
  });

  final String title;
  final bool debugShowCheckedModeBanner;
  final ThemeData? theme;
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;
  final Widget home;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => MaterialApp(
      title: title,
      debugShowCheckedModeBanner: debugShowCheckedModeBanner,
      theme: theme,
      scaffoldMessengerKey: scaffoldMessengerKey,
      locale: appLanguage.locale,
      supportedLocales: const [Locale('en'), Locale('pl')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home,
    ),
  );
}
