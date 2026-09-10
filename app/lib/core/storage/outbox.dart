import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One queued write that was made while offline.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.method,
    required this.path,
    required this.body,
    required this.queuedAt,
  });

  final String id;
  final String method;
  final String path;
  final Map<String, dynamic> body;
  final int queuedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'method': method,
    'path': path,
    'body': body,
    'queuedAt': queuedAt,
  };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) => OutboxEntry(
    id: json['id'] as String,
    method: json['method'] as String,
    path: json['path'] as String,
    body: (json['body'] as Map).cast<String, dynamic>(),
    queuedAt: (json['queuedAt'] as num).toInt(),
  );
}

/// Offline-first writes: workouts, meals and sleep sessions carry a client-minted
/// UUIDv7 and the API treats POST as an upsert on that id, so replaying a queued
/// entry is safe and cannot create duplicates.
///
/// Backed by shared_preferences rather than a file: the queue is a handful of
/// small JSON objects, and prefs is the one storage that works identically on
/// Android, iOS and web.
class Outbox {
  Outbox._(this._prefs, this._entries);

  static const _key = 'chiphealth.outbox';

  final SharedPreferences _prefs;
  final List<OutboxEntry> _entries;

  static Future<Outbox> open() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return Outbox._(prefs, []);
    try {
      final entries = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => OutboxEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
      return Outbox._(prefs, entries);
    } catch (_) {
      // A corrupt queue must not brick the app; start clean.
      return Outbox._(prefs, []);
    }
  }

  List<OutboxEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;

  Future<void> add(OutboxEntry entry) async {
    // Re-queueing the same row replaces it: only the latest state matters.
    _entries.removeWhere((e) => e.id == entry.id && e.path == entry.path);
    _entries.add(entry);
    await _persist();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }
}
