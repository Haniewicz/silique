import 'package:flutter/material.dart';

import '../l10n/app_language.dart';

/// The same preference control is used in first-run setup and Settings.
class LanguagePicker extends StatefulWidget {
  const LanguagePicker({super.key});

  @override
  State<LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<LanguagePicker> {
  bool _busy = false;
  bool _saveFailed = false;

  Future<void> _select(String code) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _saveFailed = false;
    });
    try {
      await appLanguage.setLanguage(code);
    } catch (_) {
      if (mounted) {
        setState(() => _saveFailed = true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryNative() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await appLanguage.retryNativeSynchronization();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => Column(
      key: const Key('language-picker'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Język', 'Language'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('language-en'),
              label: const Text('English'),
              selected: appLanguage.languageCode == 'en',
              onSelected: _busy ? null : (_) => _select('en'),
            ),
            ChoiceChip(
              key: const Key('language-pl'),
              label: const Text('Polski'),
              selected: appLanguage.languageCode == 'pl',
              onSelected: _busy ? null : (_) => _select('pl'),
            ),
          ],
        ),
        if (appLanguage.nativeSyncPending) ...[
          const SizedBox(height: 8),
          Text(
            tr(
              'Język zapisany. Niektóre elementy systemowe nie zostały odświeżone.',
              'Language saved. Some system components could not be refreshed.',
            ),
          ),
          TextButton(
            key: const Key('language-native-retry'),
            onPressed: _busy ? null : _retryNative,
            child: Text(tr('Ponów odświeżanie', 'Retry refresh')),
          ),
        ],
        if (_saveFailed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr(
                'Nie udało się zapisać języka. Spróbuj ponownie.',
                'Could not save the language. Please try again.',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}
