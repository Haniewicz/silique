import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';
import 'notebook.dart';

/// Untrusted native intents carry identities, never note plaintext.
class WidgetAction {
  const WidgetAction({
    required this.action,
    required this.requestId,
    this.vaultId,
    this.noteId,
  });
  final String action, requestId;
  final String? vaultId, noteId;
  static bool _id(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value);
  static WidgetAction? parse(Object? raw) {
    if (raw is! Map || !_id(raw['requestId'])) return null;
    final type = raw['action'];
    if (type != 'openNote' && type != 'newNote' && type != 'journal') {
      return null;
    }
    if (raw['vaultId'] != null && !_id(raw['vaultId'])) return null;
    if (type == 'openNote' && (!_id(raw['vaultId']) || !_id(raw['noteId']))) {
      return null;
    }
    return WidgetAction(
      action: type as String,
      requestId: raw['requestId'] as String,
      vaultId: raw['vaultId'] as String?,
      noteId: type == 'openNote' ? raw['noteId'] as String : null,
    );
  }

  String? targetVault(Notebook notebook) {
    if (vaultId != null) return vaultId;
    final ordinary = notebook.vaults.where((v) => v.mode == 'account');
    return ordinary
            .where((v) => v.id == notebook.lastVaultId)
            .firstOrNull
            ?.id ??
        ordinary.firstOrNull?.id;
  }

  bool isEligible(Notebook notebook) {
    final id = targetVault(notebook);
    if (id != null && notebook.vaultDeletionPending(id)) return false;
    final vault = notebook.vaults.where((v) => v.id == id).firstOrNull;
    if (vault == null ||
        vault.mode != 'account' ||
        !notebook.unlocked.containsKey(id)) {
      return false;
    }
    if (action == 'newNote' || action == 'journal') return true;
    final note = notebook.notes[id]?[noteId];
    return note != null && note.vaultId == id && !note.hidden && !note.deleted;
  }

  bool waitsForUnlock(Notebook notebook) {
    final id = targetVault(notebook);
    if (id != null && notebook.vaultDeletionPending(id)) return false;
    final vault = notebook.vaults.where((v) => v.id == id).firstOrNull;
    return vault?.mode == 'account' && !notebook.unlocked.containsKey(id);
  }
}

/// A native launcher snapshot contains only ordinary account-mode notes.
/// Password vaults are excluded even when their in-app session is unlocked.
class AndroidWidgets {
  AndroidWidgets({
    required this.notebook,
    MethodChannel? channel,
    bool? enabled,
  }) : channel = channel ?? const MethodChannel('silique.notes/widgets'),
       enabled = enabled ?? Platform.isAndroid {
    notebook.revokeVaultSnapshot = _revokeVault;
  }
  final Notebook notebook;
  final MethodChannel channel;
  final bool enabled;
  String? _published;
  StreamSubscription<void>? _changes, _access;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  Object? lastError;
  final _waitingActions = Queue<WidgetAction>();
  final _seen = <String>{};
  late final _actions = StreamController<WidgetAction>.broadcast(
    onListen: _emitWaiting,
  );
  Stream<WidgetAction> get actions => _actions.stream;
  Future<void>? _draining;
  bool _drainRequested = false, _started = false;
  final _revokedVaults = <String>{};

  Future<void> _revokeVault(String id) {
    if (!enabled || _disposed) return Future.value();
    _revokedVaults.add(id);
    _waitingActions.removeWhere((action) => action.vaultId == id);
    final next = _tail.then((_) async {
      await channel.invokeMethod<void>('removeVaultSnapshot', id);
      _published = null;
    });
    _tail = next.catchError((Object error) {
      lastError = error;
    });
    return next;
  }

  void _emitWaiting() {
    if (_disposed || !_actions.hasListener) return;
    final count = _waitingActions.length;
    for (var i = 0; i < count; i++) {
      final action = _waitingActions.removeFirst();
      if (action.isEligible(notebook)) {
        _actions.add(action);
      } else if (action.waitsForUnlock(notebook)) {
        _waitingActions.add(action);
      }
    }
  }

  Future<void> _drain() {
    _drainRequested = true;
    if (_draining != null) return _draining!;
    final done = Completer<void>();
    _draining = done.future;
    () async {
      try {
        while (_drainRequested && !_disposed) {
          _drainRequested = false;
          while (!_disposed) {
            final raw = await channel.invokeMethod<Object?>(
              'takePendingAction',
            );
            if (raw == null) break;
            final action = WidgetAction.parse(raw);
            if (action == null || !_seen.add(action.requestId)) continue;
            if (_seen.length > 512) _seen.remove(_seen.first);
            if (!action.isEligible(notebook) &&
                !action.waitsForUnlock(notebook)) {
              continue;
            }
            _waitingActions.add(action);
            _emitWaiting();
          }
        }
        done.complete();
      } catch (error, stack) {
        lastError = error;
        done.completeError(error, stack);
      } finally {
        _draining = null;
      }
    }();
    return done.future;
  }

  Future<void> start() async {
    if (_disposed) return;
    if (!enabled) {
      await notebook.retryVaultDeletions();
      return;
    }
    if (!_started) {
      _started = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'actionAvailable') await _drain();
      });
      await _drain();
    }
    _changes ??= notebook.localChanges.listen((_) {
      unawaited(
        refresh().catchError((Object error) {
          lastError = error;
        }),
      );
    });
    _access ??= notebook.accessChanges.listen((_) {
      _emitWaiting();
      unawaited(
        refresh().catchError((Object error) {
          lastError = error;
        }),
      );
    });
    await notebook.retryVaultDeletions();
    await refresh();
  }

  int _suppression = 0;

  /// Remove the native search/list index before making a note private. If
  /// revocation fails, do not run the mutation or risk an old cached plaintext.
  Future<T> withoutSnapshot<T>(Future<T> Function() mutation) async {
    _suppression++;
    try {
      await refresh();
      return await mutation();
    } finally {
      _suppression--;
      await refresh();
    }
  }

  Map<String, Object?> _snapshot() {
    if (_suppression > 0) {
      return {'schema': 1, 'lastVaultId': null, 'notes': <Object>[]};
    }
    final vaults =
        notebook.vaults
            .where(
              (v) =>
                  v.mode == 'account' &&
                  !_revokedVaults.contains(v.id) &&
                  !notebook.vaultDeletionPending(v.id) &&
                  notebook.unlocked.containsKey(v.id),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final notes =
        <Note>[
          for (final vault in vaults)
            for (final note
                in notebook.notes[vault.id]?.values ?? const <Note>[])
              if (note.vaultId == vault.id && !note.hidden && !note.deleted)
                note,
        ]..sort((a, b) {
          final time = b.updatedAt.compareTo(a.updatedAt);
          return time != 0 ? time : a.id.compareTo(b.id);
        });
    return {
      'schema': 1,
      'lastVaultId': vaults.any((v) => v.id == notebook.lastVaultId)
          ? notebook.lastVaultId
          : vaults.firstOrNull?.id,
      'notes': [
        for (final note in notes)
          {
            'id': note.id,
            'vaultId': note.vaultId,
            'title': note.title,
            'preview': String.fromCharCodes(
              note.body.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(180),
            ),
            'searchText':
                '${note.title}\n${note.body}\n${note.folder}\n${note.tags.join(' ')}',
            'folder': note.folder,
            'updatedAt': note.updatedAt.toIso8601String(),
          },
      ],
    };
  }

  bool get _hasUnlockedAccount => notebook.vaults.any(
    (v) => v.mode == 'account' && notebook.unlocked.containsKey(v.id),
  );

  Future<void> refresh() {
    if (!enabled || _disposed) return Future.value();
    final next = _tail.then((_) async {
      if (_disposed) return;
      // A locked app cannot compute a truthful list. Keep the last encrypted
      // snapshot so the launcher shows notes without demanding an app unlock;
      // an empty list here would also wipe rows the user can still read.
      if (_suppression == 0 && !_hasUnlockedAccount) return;
      // Build at execution time; queued updates must never republish stale data.
      final snapshot = _snapshot();
      final encoded = jsonEncode(snapshot);
      if (encoded == _published) return;
      if ((snapshot['notes'] as List).isEmpty) {
        await channel.invokeMethod<void>('clearSnapshot');
      } else {
        await channel.invokeMethod<void>('publishSnapshot', snapshot);
      }
      _published = encoded;
      lastError = null;
    });
    _tail = next.catchError((Object error) {
      lastError = error;
    });
    return next;
  }

  Future<void> dispose() async {
    _disposed = true;
    if (notebook.revokeVaultSnapshot == _revokeVault) {
      notebook.revokeVaultSnapshot = null;
    }
    if (enabled && _started) channel.setMethodCallHandler(null);
    _waitingActions.clear();
    await _changes?.cancel();
    await _access?.cancel();
    await _tail;
    await _draining;
    await _actions.close();
  }
}
