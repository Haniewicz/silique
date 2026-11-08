part of 'notebook.dart';

extension NotebookVaultDeletion on Notebook {
  bool vaultDeletionPending(String id) => _deletingVaults.contains(id);

  void _requireLiveVault(String id) {
    if (vaultDeletionPending(id) ||
        storage.isVaultDeleted(id) ||
        !storage.vaults().any((v) => v.id == id)) {
      throw StateError(
        tr(
          'Vault usunięto lub oczekuje na dokończenie usuwania.',
          'The vault has been deleted or is awaiting deletion.',
        ),
      );
    }
  }

  Future<void> deleteVault(Vault vault, {required String confirmation}) async {
    _requireLiveVault(vault.id);
    if (_syncing || _hiddenMoving || _vaultDeletionBusy) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie synchronizacji lub przenoszenia.',
          'Wait for synchronization or relocation to finish.',
        ),
      );
    }
    final current = vaults.firstWhere((v) => v.id == vault.id);
    if (!unlocked.containsKey(vault.id) || confirmation != current.name) {
      throw StateError(
        tr(
          'Odblokuj vault i wpisz dokładnie jego nazwę.',
          'Unlock the vault and enter its exact name.',
        ),
      );
    }
    _checkDeletionOwner(current);
    final client = api;
    final owner = current.owner;
    final version = current.version;
    _vaultDeletionBusy = true;
    _deletingVaults.add(vault.id);
    try {
      await serialized(() async {
        if (owner != null) {
          final discovery = await client!.request(
            'GET',
            '/.well-known/silique',
          );
          if ((discovery['features'] as Json?)?['vault_deletion'] != true) {
            throw StateError(
              tr(
                'Serwer nie obsługuje usuwania vaultów. Dane pozostają bez zmian.',
                'The server does not support vault deletion. Data remains unchanged.',
              ),
            );
          }
        }
        final latest = vaults.firstWhere((v) => v.id == vault.id);
        _checkDeletionOwner(latest);
        if (latest.owner != owner ||
            latest.version != version ||
            latest.name != confirmation ||
            !unlocked.containsKey(vault.id) ||
            api != client) {
          throw StateError(
            tr(
              'Stan vaulta zmienił się. Otwórz potwierdzenie ponownie.',
              'The vault\'s state has changed. Open the confirmation again.',
            ),
          );
        }
        final intent = <String, dynamic>{
          'owner': owner,
          'expectedVersion': version,
          'acknowledged': owner == null,
        };
        await storage.beginVaultDeletion(vault.id, jsonEncode(intent));
        await _resumeVaultDeletion(vault.id, intent);
      });
    } catch (_) {
      if (!(await storage.deletionIntents()).containsKey(vault.id) &&
          !storage.isVaultDeleted(vault.id)) {
        _deletingVaults.remove(vault.id);
      }
      rethrow;
    } finally {
      _vaultDeletionBusy = false;
    }
  }

  void _checkDeletionOwner(Vault vault) {
    if (vault.owner == null) {
      if (vault.syncEnabled) {
        throw StateError(
          tr(
            'Niespójne przypisanie vaulta do konta.',
            'Inconsistent vault account association.',
          ),
        );
      }
    } else if (!vault.syncEnabled ||
        session?.owner != vault.owner ||
        api == null) {
      throw StateError(
        tr(
          'Połącz konto właściciela i włącz synchronizację. Usuwanie nie może być tylko lokalne.',
          'Connect the owner\'s account and enable synchronization. Deletion cannot be local only.',
        ),
      );
    }
  }

  Future<void> retryVaultDeletions() async {
    if (_syncing || _hiddenMoving) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie synchronizacji.',
          'Wait for synchronization to finish.',
        ),
      );
    }
    // Do not enqueue a no-op recovery: widget startup would otherwise replace
    // the real-I/O serialization tail with a fake-async test-zone continuation.
    if ((await storage.deletionIntents()).isEmpty) return;
    await serialized(() async {
      // Startup, manual retry and sync can request recovery concurrently. Read
      // the journal only after earlier recovery has finished, never replay a
      // stale pre-ACK snapshot of it.
      final intents = await storage.deletionIntents();
      _deletingVaults.addAll(intents.keys);
      Object? failure;
      for (final entry in intents.entries) {
        final intent = jsonDecode(entry.value) as Json;
        final owner = intent['owner'];
        if (intent['acknowledged'] != true &&
            (owner != session?.owner || api == null)) {
          continue;
        }
        try {
          await _resumeVaultDeletion(entry.key, intent);
        } catch (error) {
          // One stuck intent must never block another intent, a tombstone
          // download or ordinary content sync. It stays durably fenced and is
          // retried later; the caller still receives the failure.
          failure ??= error;
        }
      }
      if (failure != null) throw failure;
    });
  }

  Future<void> _resumeVaultDeletion(String id, Json intent) async {
    if (intent['acknowledged'] != true) {
      final client = api;
      if (client == null || session?.owner != intent['owner']) {
        throw StateError(
          tr(
            'Połącz konto właściciela, aby dokończyć usuwanie.',
            'Connect the owner\'s account to finish deletion.',
          ),
        );
      }
      Json response;
      final priorAttempt = intent['attempted'] == true;
      intent = {...intent, 'attempted': true};
      await storage.beginVaultDeletion(id, jsonEncode(intent));
      try {
        response = await client.request(
          'DELETE',
          '/v1/vaults/$id',
          body: {'expectedVersion': intent['expectedVersion']},
        );
      } on ApiException catch (error) {
        // Explicit rejection proves this attempt did not commit. Timeouts and
        // server failures remain fenced until an idempotent retry resolves them.
        if (!priorAttempt &&
            [400, 401, 403, 404, 409, 422, 429].contains(error.status)) {
          await storage.cancelVaultDeletion(id);
          _deletingVaults.remove(id);
        }
        rethrow;
      }
      if (response['deleted'] != true || response['vaultId'] != id) {
        throw FormatException(
          tr(
            'Brak jednoznacznego potwierdzenia usunięcia. Ponów dokończenie usuwania.',
            'Deletion was not clearly acknowledged. Retry finishing the deletion.',
          ),
        );
      }
      intent = {...intent, 'acknowledged': true};
      await storage.beginVaultDeletion(id, jsonEncode(intent));
    }
    await _finishVaultDeletion(id);
  }

  Future<void> _acceptVaultTombstone(String id, String owner) async {
    if (storage.isVaultDeleted(id)) return;
    final local = vaults.where((v) => v.id == id).firstOrNull;
    if (local != null && local.owner != owner) return;
    _deletingVaults.add(id);
    await storage.beginVaultDeletion(
      id,
      jsonEncode({'owner': owner, 'acknowledged': true}),
    );
    await _finishVaultDeletion(id);
  }

  /// An attempt whose outcome stayed unknown keeps its fence. The authoritative
  /// vault list can resolve it without ever inferring erasure: when the account
  /// still owns the vault, the remote deletion did not commit, so lifting the
  /// fence cannot resurrect retired data. Absent ids stay fenced.
  Future<void> _reconcileVaultDeletionIntents(String owner, List remote) async {
    for (final entry in (await storage.deletionIntents()).entries) {
      final intent = jsonDecode(entry.value) as Json;
      if (intent['acknowledged'] == true ||
          intent['attempted'] != true ||
          intent['owner'] != owner ||
          storage.isVaultDeleted(entry.key)) {
        continue;
      }
      if (!remote.any((item) => (item as Json)['id'] == entry.key)) continue;
      await storage.cancelVaultDeletion(entry.key);
      _deletingVaults.remove(entry.key);
      _accessChanges.add(null);
      _localChanges.add(null);
    }
  }

  Future<void> _finishVaultDeletion(String id) async {
    await revokeVaultSnapshot?.call(id);
    final key = unlocked.remove(id);
    key?.fillRange(0, key.length, 0);
    notes.remove(id);
    _names.remove(id);
    _meta.remove(id);
    _knownHeads.removeWhere((key, _) => key.startsWith('$id:'));
    // The hidden password is shared across vaults; revoke only its in-memory
    // session, never its persisted wraps or the installation/account keys.
    _hiddenGeneration++;
    _hiddenLockRequested = true;
    _hiddenAutoLockTimer?.cancel();
    _hiddenKey?.fillRange(0, _hiddenKey!.length, 0);
    _hiddenKey = null;
    for (final key in _hiddenKeys.values) {
      key.fillRange(0, key.length, 0);
    }
    _hiddenKeys.clear();
    _hiddenActiveConfig = null;
    _hiddenActivity = null;
    _hiddenStateChanges.add(null);
    // Synchronous revocation lets Home wipe selected controllers before SQL
    // cleanup. Failure keeps the durable intent fenced for a later retry.
    _vaultDeletions.add(id);
    if (_lastVaultId == id) {
      final next = vaults.where((v) => v.id != id).firstOrNull?.id;
      if (next == null) {
        await keys.delete('nova.lastVault');
      } else {
        await keys.write('nova.lastVault', next);
      }
      _lastVaultId = next;
    }
    await storage.eraseVault(id);
    _deletingVaults.remove(id);
    _accessChanges.add(null);
    _localChanges.add(null);
  }
}
