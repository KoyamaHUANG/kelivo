import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/settings_provider.dart';
import '../chat/chat_service.dart';
import 'heartbeat_proactive_api.dart';
import 'heartbeat_proactive_models.dart';
import 'heartbeat_proactive_store.dart';

class HeartbeatProactiveSyncResult {
  const HeartbeatProactiveSyncResult({
    required this.insertedMessages,
    required this.cursorBefore,
    required this.cursorAfter,
    this.completed = true,
  });

  final List<ChatMessage> insertedMessages;
  final int cursorBefore;
  final int cursorAfter;
  final bool completed;

  static const empty = HeartbeatProactiveSyncResult(
    insertedMessages: <ChatMessage>[],
    cursorBefore: 0,
    cursorAfter: 0,
  );
}

/// Confirmation returned to the one real user-chat route. Nothing in this
/// service is used by title, summary, translation, OCR, or other utilities.
class HeartbeatProactiveChatPreparation {
  const HeartbeatProactiveChatPreparation(this.headers);

  final Map<String, String>? headers;

  static const none = HeartbeatProactiveChatPreparation(null);
}

class HeartbeatProactiveSyncService {
  HeartbeatProactiveSyncService({
    required this.chatService,
    required this.store,
    HeartbeatProactiveApi? api,
    this.onMessagesPersisted,
    DateTime Function()? now,
  }) : _api = api ?? HttpHeartbeatProactiveApi(),
       _now = now ?? DateTime.now;

  static const Duration capabilityTimeout = Duration(milliseconds: 2500);
  static const Duration preSendBudget = Duration(seconds: 3);
  static const Duration negativeCapabilityTtl = Duration(minutes: 5);
  static const int defaultPageLimit = 50;
  static const int maxPagesPerSync = 20;
  static const String _capabilityProbeConversationId =
      '__kelivo_capability_probe__';

  final ChatService chatService;
  final HeartbeatProactiveStore store;
  final HeartbeatProactiveApi _api;
  final Future<void> Function(List<ChatMessage> messages)? onMessagesPersisted;
  final DateTime Function() _now;
  final Map<String, DateTime> _negativeUntil = <String, DateTime>{};
  final Map<String, Future<HeartbeatProactiveSyncResult>> _inFlight =
      <String, Future<HeartbeatProactiveSyncResult>>{};

  /// Probes only openai-compatible providers, and only persists a positive
  /// answer. Negative answers are intentionally session-scoped and short.
  Future<bool> supportsProactiveSync({
    required ProviderConfig config,
    required String modelId,
  }) async {
    final kind = ProviderConfig.classify(
      config.id,
      explicitType: config.providerType,
    );
    if (kind != ProviderKind.openai) return false;
    final normalizedBaseUrl = normalizeHeartbeatBaseUrl(config.baseUrl);
    if (normalizedBaseUrl.isEmpty ||
        buildHeartbeatProactiveEventsEndpoint(config) == null) {
      return false;
    }
    final identity = heartbeatProviderIdentity(config.id, normalizedBaseUrl);
    if (await store.hasPositiveCapability(identity)) return true;
    final negativeUntil = _negativeUntil[identity];
    if (negativeUntil != null && negativeUntil.isAfter(_now())) return false;

    try {
      final response = await _api.fetchEvents(
        config: config,
        modelId: modelId,
        conversationId: _capabilityProbeConversationId,
        afterSeq: 0,
        limit: 1,
        timeout: capabilityTimeout,
      );
      final supported =
          response.statusCode == 200 &&
          response.body is Map &&
          (response.body as Map)['object'] == 'proactive_event_list';
      if (supported) {
        await store.setPositiveCapability(identity);
        _negativeUntil.remove(identity);
        _log('heartbeat_capability=true');
        return true;
      }
      _negativeUntil[identity] = _now().add(negativeCapabilityTtl);
      _log('heartbeat_capability=false status=${response.statusCode}');
      return false;
    } catch (_) {
      _negativeUntil[identity] = _now().add(negativeCapabilityTtl);
      _log('heartbeat_capability=false network_error');
      return false;
    }
  }

  /// Runs immediately before persisting a real user message. It first binds
  /// the conversation after a confirmed capability probe, then waits only a
  /// short bounded interval for earlier proactive assistant messages.
  Future<HeartbeatProactiveChatPreparation> prepareForUserChat({
    required Conversation conversation,
    required ProviderConfig config,
    required String providerId,
    required String modelId,
  }) async {
    if (!_isPersistentExistingConversation(conversation.id)) {
      return HeartbeatProactiveChatPreparation.none;
    }
    final started = _now();
    final supported = await supportsProactiveSync(
      config: config,
      modelId: modelId,
    );
    if (!supported) return HeartbeatProactiveChatPreparation.none;

    final binding = HeartbeatProactiveBinding(
      conversationId: conversation.id,
      providerId: providerId,
      modelId: modelId,
      assistantId: _cleanOptional(conversation.assistantId),
      normalizedBaseUrl: normalizeHeartbeatBaseUrl(config.baseUrl),
    );
    await store.upsertBinding(binding);
    _log('conversation_bound=true');

    final elapsed = _now().difference(started);
    final remaining = preSendBudget - elapsed;
    if (!remaining.isNegative && remaining > Duration.zero) {
      try {
        await syncBinding(binding, config: config).timeout(remaining);
      } catch (_) {
        // The in-flight sync is allowed to finish later. It must never stop
        // normal chat when Railway or the local network is unavailable.
        _log('pre_send_sync_timeout_or_error');
      }
    }
    // A formerly-supported endpoint may have been replaced in place. If the
    // just-completed sync observed a definitive incompatible response, it
    // cleared the positive cache; do not send routing headers in that case.
    if (!await supportsProactiveSync(config: config, modelId: modelId)) {
      return HeartbeatProactiveChatPreparation.none;
    }
    return HeartbeatProactiveChatPreparation(<String, String>{
      heartbeatConversationHeaderName: conversation.id,
      if (_cleanOptional(conversation.assistantId) case final assistantId?)
        heartbeatAssistantHeaderName: assistantId,
    });
  }

  Future<HeartbeatProactiveSyncResult> syncConversation({
    required String conversationId,
    required SettingsProvider settings,
  }) async {
    if (!_isPersistentExistingConversation(conversationId)) {
      return HeartbeatProactiveSyncResult.empty;
    }
    final binding = await store.getBinding(conversationId);
    if (binding == null) return HeartbeatProactiveSyncResult.empty;
    final config = settings.providerConfigs[binding.providerId];
    if (config == null ||
        normalizeHeartbeatBaseUrl(config.baseUrl) !=
            binding.normalizedBaseUrl) {
      return HeartbeatProactiveSyncResult.empty;
    }
    if (!await supportsProactiveSync(
      config: config,
      modelId: binding.modelId,
    )) {
      return HeartbeatProactiveSyncResult.empty;
    }
    return syncBinding(binding, config: config);
  }

  /// Current conversation is intentionally first; then at most two unrelated
  /// bindings are pulled concurrently so resume cannot fan out unbounded GETs.
  Future<void> syncKnownBindings({
    required SettingsProvider settings,
    String? currentConversationId,
  }) async {
    if ((currentConversationId ?? '').isNotEmpty) {
      await syncConversation(
        conversationId: currentConversationId!,
        settings: settings,
      );
    }
    final bindings = await store.getBindings();
    final pending = <Future<void>>[];
    for (final binding in bindings) {
      if (binding.conversationId == currentConversationId) continue;
      pending.add(
        syncConversation(
          conversationId: binding.conversationId,
          settings: settings,
        ).then<void>((_) {}),
      );
      if (pending.length == 2) {
        await Future.wait(pending);
        pending.clear();
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  Future<HeartbeatProactiveSyncResult> syncBinding(
    HeartbeatProactiveBinding binding, {
    required ProviderConfig config,
  }) {
    if (!_isPersistentExistingConversation(binding.conversationId)) {
      return Future<HeartbeatProactiveSyncResult>.value(
        HeartbeatProactiveSyncResult.empty,
      );
    }
    final key = '${binding.providerIdentity}|${binding.conversationId}';
    final active = _inFlight[key];
    if (active != null) return active;
    late final Future<HeartbeatProactiveSyncResult> future;
    future = _syncBindingImpl(binding, config: config).whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<HeartbeatProactiveSyncResult> _syncBindingImpl(
    HeartbeatProactiveBinding binding, {
    required ProviderConfig config,
  }) async {
    final cursorBefore = await store.getCursor(binding);
    var cursor = cursorBefore;
    final inserted = <ChatMessage>[];
    _log('sync_started cursor_before=$cursorBefore');
    for (var pageNumber = 0; pageNumber < maxPagesPerSync; pageNumber++) {
      final pageStartCursor = cursor;
      HeartbeatProactiveHttpResponse response;
      try {
        response = await _api.fetchEvents(
          config: config,
          modelId: binding.modelId,
          conversationId: binding.conversationId,
          afterSeq: cursor,
          limit: defaultPageLimit,
          assistantId: binding.assistantId,
        );
      } catch (_) {
        _log('sync_network_error cursor_after=$cursor');
        return HeartbeatProactiveSyncResult(
          insertedMessages: List<ChatMessage>.unmodifiable(inserted),
          cursorBefore: cursorBefore,
          cursorAfter: cursor,
          completed: false,
        );
      }

      final identity = binding.providerIdentity;
      if (response.statusCode == 404 ||
          (response.statusCode == 200 &&
              (response.body is! Map ||
                  (response.body as Map)['object'] !=
                      'proactive_event_list'))) {
        await store.clearPositiveCapability(identity);
        _negativeUntil[identity] = _now().add(negativeCapabilityTtl);
        _log('heartbeat_capability_cleared');
        return HeartbeatProactiveSyncResult(
          insertedMessages: List<ChatMessage>.unmodifiable(inserted),
          cursorBefore: cursorBefore,
          cursorAfter: cursor,
          completed: false,
        );
      }
      if (response.statusCode != 200) {
        _log('sync_http_status=${response.statusCode}');
        return HeartbeatProactiveSyncResult(
          insertedMessages: List<ChatMessage>.unmodifiable(inserted),
          cursorBefore: cursorBefore,
          cursorAfter: cursor,
          completed: false,
        );
      }

      final page = HeartbeatProactivePage.tryParse(
        response.body,
        expectedConversationId: binding.conversationId,
      );
      if (page == null) {
        _log('sync_protocol_error');
        return HeartbeatProactiveSyncResult(
          insertedMessages: List<ChatMessage>.unmodifiable(inserted),
          cursorBefore: cursorBefore,
          cursorAfter: cursor,
          completed: false,
        );
      }

      final pageInserted = <ChatMessage>[];
      for (final parsed in page.events) {
        final seq = parsed.seq!;
        if (seq <= cursor) continue;
        if (parsed.kind ==
            HeartbeatProactiveEventParseKind.malformedConsumable) {
          _log('sync_malformed_event_consumed seq=$seq');
          await store.setCursor(binding, seq);
          cursor = seq;
          continue;
        }
        final event = parsed.event!;
        try {
          final message = event.toChatMessage(binding);
          final insertedNow = await chatService.appendExternalAssistantMessage(
            message,
          );
          if (insertedNow) {
            inserted.add(message);
            pageInserted.add(message);
          }
          // A stable-id duplicate is a successfully consumed event too.
          await store.setCursor(binding, seq);
          cursor = seq;
        } catch (_) {
          // Do not advance beyond a failed database write. A later sync can
          // retry the exact event, and its stable id preserves idempotency.
          _log('sync_message_write_failed seq=$seq');
          return HeartbeatProactiveSyncResult(
            insertedMessages: List<ChatMessage>.unmodifiable(inserted),
            cursorBefore: cursorBefore,
            cursorAfter: cursor,
            completed: false,
          );
        }
      }
      if (pageInserted.isNotEmpty) {
        try {
          await onMessagesPersisted?.call(pageInserted);
        } catch (_) {
          // UI/cache presentation failures cannot undo a committed message or
          // block the durable cursor. ChatService has already notified.
          _log('sync_ui_publish_failed');
        }
      }

      if (page.nextAfterSeq > cursor) {
        await store.setCursor(binding, page.nextAfterSeq);
        cursor = page.nextAfterSeq;
      }
      if (!page.hasMore) {
        _log(
          'sync_completed event_count=${inserted.length} cursor_after=$cursor',
        );
        return HeartbeatProactiveSyncResult(
          insertedMessages: List<ChatMessage>.unmodifiable(inserted),
          cursorBefore: cursorBefore,
          cursorAfter: cursor,
        );
      }
      // A server that says has_more without moving the cursor would otherwise
      // cause an infinite loop. Leave the cursor intact and retry later.
      if (cursor <= pageStartCursor) break;
    }
    _log('sync_page_limit_reached cursor_after=$cursor');
    return HeartbeatProactiveSyncResult(
      insertedMessages: List<ChatMessage>.unmodifiable(inserted),
      cursorBefore: cursorBefore,
      cursorAfter: cursor,
      completed: false,
    );
  }

  bool _isPersistentExistingConversation(String conversationId) =>
      conversationId.trim().isNotEmpty &&
      !chatService.isTemporaryConversation(conversationId) &&
      chatService.getConversation(conversationId) != null;

  static String? _cleanOptional(String? value) {
    final cleaned = (value ?? '').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  void _log(String message) => debugPrint('[HeartbeatProactiveSync] $message');
}
