import '../core/updates.dart';
import 'notebook.dart';

class PreparedWindowsUpdate implements WindowsUpdateHandoff {
  PreparedWindowsUpdate._(this.notebook, this.blockInput, this.close);
  final Notebook notebook;
  final void Function(bool) blockInput;
  final Future<void> Function() close;
  bool _finished = false;
  bool _launched = false;
  Future<void>? _committing;
  static Future<PreparedWindowsUpdate> prepare({
    required Notebook notebook,
    required void Function(bool) blockInput,
    required Future<void> Function() beforeClose,
    required Future<void> Function() close,
  }) async {
    blockInput(true);
    try {
      await notebook.prepareForUpdate(flush: beforeClose);
      return PreparedWindowsUpdate._(notebook, blockInput, close);
    } catch (_) {
      blockInput(false);
      rethrow;
    }
  }

  @override
  Future<void> commit() {
    if (_finished) return Future.value();
    // Native launch is irreversible, even when window destruction fails.
    _launched = true;
    return _committing ??= _commit();
  }

  Future<void> _commit() async {
    try {
      await Future<void>.sync(close);
      _finished = true;
    } finally {
      // Coalesce concurrent closes, but allow a controlled retry after failure.
      _committing = null;
    }
  }

  @override
  Future<void> abort() async {
    if (_launched || _finished) return;
    _finished = true;
    notebook.resumeAfterUpdate();
    blockInput(false);
  }
}
