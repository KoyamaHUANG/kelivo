import 'dart:convert';

import '../../database/business_preferences.dart';

import 'heartbeat_proactive_models.dart';

/// Local key-value state only. API keys never enter this store.
///
/// Kelivo routes persistent user settings through [BusinessPreferences], which
/// provides the app's existing local persistence and serialized write queue.
/// This adds no table or ProviderConfig field.
class HeartbeatProactiveStore {
  HeartbeatProactiveStore({required this.preferences});

  static const _bindingsKey = 'heartbeat_proactive_bindings_v1';
  static const _capabilityPrefix = 'heartbeat_proactive_capability_v1:';
  static const _archiveCapabilityPrefix =
      'heartbeat_archive_identity_capability_v1:';
  static const _cursorPrefix = 'heartbeat_proactive_cursor_v1:';

  final BusinessPreferences preferences;

  Future<void> _ensureLoaded() => preferences.load();

  static String _safeKeyPart(String value) =>
      base64UrlEncode(utf8.encode(value));

  String _capabilityKey(String providerIdentity) =>
      '$_capabilityPrefix${_safeKeyPart(providerIdentity)}';

  String _archiveCapabilityKey(String providerIdentity) =>
      '$_archiveCapabilityPrefix${_safeKeyPart(providerIdentity)}';

  String _cursorKey(HeartbeatProactiveBinding binding) =>
      '$_cursorPrefix${_safeKeyPart(binding.providerIdentity)}:${_safeKeyPart(binding.conversationId)}';

  Future<bool> hasPositiveCapability(String providerIdentity) async {
    await _ensureLoaded();
    return preferences.getBool(_capabilityKey(providerIdentity)) == true;
  }

  Future<void> setPositiveCapability(String providerIdentity) async {
    await _ensureLoaded();
    await preferences.setBool(_capabilityKey(providerIdentity), true);
  }

  Future<void> clearPositiveCapability(String providerIdentity) async {
    await _ensureLoaded();
    await preferences.remove(_capabilityKey(providerIdentity));
  }

  /// A separate cache from proactive capability. Zero is a completed probe
  /// against an old server; 1 is the Protocol 1 capability.
  Future<int?> getArchiveIdentityProtocolVersion(
    String providerIdentity,
  ) async {
    await _ensureLoaded();
    final version = preferences.getInt(_archiveCapabilityKey(providerIdentity));
    return version == null || version < 0 ? null : version;
  }

  Future<void> setArchiveIdentityProtocolVersion(
    String providerIdentity,
    int version,
  ) async {
    await _ensureLoaded();
    await preferences.setInt(_archiveCapabilityKey(providerIdentity), version);
  }

  Future<void> clearArchiveIdentityProtocolVersion(
    String providerIdentity,
  ) async {
    await _ensureLoaded();
    await preferences.remove(_archiveCapabilityKey(providerIdentity));
  }

  Future<void> upsertBinding(HeartbeatProactiveBinding binding) async {
    await _ensureLoaded();
    final bindings = await getBindings();
    final next = <String, HeartbeatProactiveBinding>{
      for (final item in bindings) item.conversationId: item,
      binding.conversationId: binding,
    };
    await preferences.setString(
      _bindingsKey,
      jsonEncode(next.values.map((item) => item.toJson()).toList()),
    );
  }

  Future<HeartbeatProactiveBinding?> getBinding(String conversationId) async {
    final wanted = conversationId.trim();
    if (wanted.isEmpty) return null;
    for (final binding in await getBindings()) {
      if (binding.conversationId == wanted) return binding;
    }
    return null;
  }

  Future<List<HeartbeatProactiveBinding>> getBindings() async {
    await _ensureLoaded();
    final raw = preferences.getString(_bindingsKey);
    if (raw == null || raw.isEmpty) return const <HeartbeatProactiveBinding>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <HeartbeatProactiveBinding>[];
      return List<HeartbeatProactiveBinding>.unmodifiable([
        for (final item in decoded)
          if (HeartbeatProactiveBinding.tryParse(item) case final binding?)
            binding,
      ]);
    } catch (_) {
      return const <HeartbeatProactiveBinding>[];
    }
  }

  Future<int> getCursor(HeartbeatProactiveBinding binding) async {
    await _ensureLoaded();
    return preferences.getInt(_cursorKey(binding)) ?? 0;
  }

  Future<void> setCursor(HeartbeatProactiveBinding binding, int cursor) async {
    if (cursor < 0) return;
    await _ensureLoaded();
    await preferences.setInt(_cursorKey(binding), cursor);
  }
}
