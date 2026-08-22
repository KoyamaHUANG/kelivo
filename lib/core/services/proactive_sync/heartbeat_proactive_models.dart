import '../../models/chat_message.dart';
import '../../providers/settings_provider.dart';

const String heartbeatConversationHeaderName = 'X-Kelivo-Conversation-Id';
const String heartbeatAssistantHeaderName = 'X-Kelivo-Assistant-Id';

/// A locally persisted association between one Kelivo conversation and the
/// OpenAI-compatible provider that confirmed the Heartbeat extension.
class HeartbeatProactiveBinding {
  const HeartbeatProactiveBinding({
    required this.conversationId,
    required this.providerId,
    required this.modelId,
    required this.assistantId,
    required this.normalizedBaseUrl,
  });

  final String conversationId;
  final String providerId;
  final String modelId;
  final String? assistantId;
  final String normalizedBaseUrl;

  String get providerIdentity =>
      heartbeatProviderIdentity(providerId, normalizedBaseUrl);

  Map<String, Object?> toJson() => <String, Object?>{
    'conversationId': conversationId,
    'providerId': providerId,
    'modelId': modelId,
    'assistantId': assistantId,
    'normalizedBaseUrl': normalizedBaseUrl,
  };

  static HeartbeatProactiveBinding? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final conversationId = (raw['conversationId'] ?? '').toString().trim();
    final providerId = (raw['providerId'] ?? '').toString().trim();
    final modelId = (raw['modelId'] ?? '').toString().trim();
    final normalizedBaseUrl = (raw['normalizedBaseUrl'] ?? '')
        .toString()
        .trim();
    if (conversationId.isEmpty ||
        providerId.isEmpty ||
        modelId.isEmpty ||
        normalizedBaseUrl.isEmpty) {
      return null;
    }
    final assistantId = (raw['assistantId'] ?? '').toString().trim();
    return HeartbeatProactiveBinding(
      conversationId: conversationId,
      providerId: providerId,
      modelId: modelId,
      assistantId: assistantId.isEmpty ? null : assistantId,
      normalizedBaseUrl: normalizedBaseUrl,
    );
  }
}

/// Returns a stable identity for persisted capability and cursor keys.
String heartbeatProviderIdentity(String providerId, String normalizedBaseUrl) =>
    '${providerId.trim()}|${normalizedBaseUrl.trim()}';

/// Normalizes the URL dimensions that identify a provider endpoint without
/// retaining a query or fragment in locally persisted state.
String normalizeHeartbeatBaseUrl(String rawBaseUrl) {
  final raw = rawBaseUrl.trim();
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return raw.replaceFirst(RegExp(r'/+$'), '');
  }
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
        query: null,
        fragment: null,
      )
      .toString();
}

/// Builds the extension endpoint from the same base-url/chat-path convention
/// used by the OpenAI-compatible chat implementation.
Uri? buildHeartbeatProactiveEventsEndpoint(ProviderConfig config) {
  final rawBase = config.baseUrl.trim();
  final base = Uri.tryParse(rawBase);
  if (base == null ||
      (base.scheme != 'http' && base.scheme != 'https') ||
      base.host.isEmpty) {
    return null;
  }

  final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
  String prefix;
  if (basePath.endsWith('/v1') || basePath == '/v1') {
    prefix = basePath;
  } else {
    final configuredChatPath = (config.chatPath ?? '/chat/completions').trim();
    final chatUri = Uri.tryParse(configuredChatPath);
    var chatPath = chatUri?.path ?? configuredChatPath;
    if (!chatPath.startsWith('/')) chatPath = '/$chatPath';
    chatPath = chatPath.replaceFirst(RegExp(r'/+$'), '');
    const chatSuffix = '/chat/completions';
    // A custom OpenAI chat path may carry the API-version prefix separately
    // from baseUrl (for example, `/v1/chat/completions`). Reuse that prefix.
    if (chatPath.endsWith(chatSuffix) && chatPath != chatSuffix) {
      prefix =
          '$basePath${chatPath.substring(0, chatPath.length - chatSuffix.length)}';
    } else {
      prefix = '$basePath/v1';
    }
  }
  prefix = prefix.replaceAll(RegExp(r'/{2,}'), '/');
  if (!prefix.startsWith('/')) prefix = '/$prefix';
  return base.replace(
    path: '$prefix/proactive-events',
    query: null,
    fragment: null,
  );
}

class HeartbeatProactiveEvent {
  const HeartbeatProactiveEvent({
    required this.eventId,
    required this.seq,
    required this.conversationId,
    required this.assistantId,
    required this.createdAt,
    required this.body,
  });

  final String eventId;
  final int seq;
  final String conversationId;
  final String? assistantId;
  final DateTime createdAt;
  final String body;

  ChatMessage toChatMessage(HeartbeatProactiveBinding binding) => ChatMessage(
    id: 'heartbeat:$eventId',
    role: 'assistant',
    content: body,
    timestamp: createdAt.toLocal(),
    conversationId: conversationId,
    providerId: binding.providerId,
    modelId: binding.modelId,
    isStreaming: false,
  );
}

enum HeartbeatProactiveEventParseKind { valid, malformedConsumable, fatal }

class HeartbeatProactiveEventParseResult {
  const HeartbeatProactiveEventParseResult._({
    required this.kind,
    required this.seq,
    this.event,
  });

  HeartbeatProactiveEventParseResult.valid(HeartbeatProactiveEvent event)
    : this._(
        kind: HeartbeatProactiveEventParseKind.valid,
        seq: event.seq,
        event: event,
      );

  const HeartbeatProactiveEventParseResult.malformedConsumable({
    required int seq,
  }) : this._(
         kind: HeartbeatProactiveEventParseKind.malformedConsumable,
         seq: seq,
       );

  const HeartbeatProactiveEventParseResult.fatal()
    : this._(kind: HeartbeatProactiveEventParseKind.fatal, seq: null);

  final HeartbeatProactiveEventParseKind kind;
  final int? seq;
  final HeartbeatProactiveEvent? event;
}

class HeartbeatProactivePage {
  const HeartbeatProactivePage({
    required this.events,
    required this.nextAfterSeq,
    required this.hasMore,
  });

  final List<HeartbeatProactiveEventParseResult> events;
  final int nextAfterSeq;
  final bool hasMore;

  /// A malformed `seq` makes the complete response untrustworthy: the caller
  /// must retry from its existing cursor rather than risk skipping data.
  static HeartbeatProactivePage? tryParse(
    Object? raw, {
    required String expectedConversationId,
  }) {
    if (raw is! Map) return null;
    if (raw['object'] != 'proactive_event_list' ||
        raw['conversation_id'] != expectedConversationId ||
        raw['data'] is! List ||
        raw['next_after_seq'] is! int ||
        (raw['next_after_seq'] as int) < 0 ||
        raw['has_more'] is! bool) {
      return null;
    }
    final parsed = <HeartbeatProactiveEventParseResult>[];
    for (final item in raw['data'] as List) {
      final event = _parseEvent(
        item,
        expectedConversationId: expectedConversationId,
      );
      if (event.kind == HeartbeatProactiveEventParseKind.fatal) return null;
      parsed.add(event);
    }
    parsed.sort((left, right) => left.seq!.compareTo(right.seq!));
    return HeartbeatProactivePage(
      events: List<HeartbeatProactiveEventParseResult>.unmodifiable(parsed),
      nextAfterSeq: raw['next_after_seq'] as int,
      hasMore: raw['has_more'] as bool,
    );
  }

  static HeartbeatProactiveEventParseResult _parseEvent(
    Object? raw, {
    required String expectedConversationId,
  }) {
    if (raw is! Map || raw['seq'] is! int || (raw['seq'] as int) <= 0) {
      return const HeartbeatProactiveEventParseResult.fatal();
    }
    final seq = raw['seq'] as int;
    final eventIdRaw = raw['event_id'];
    final eventId = eventIdRaw is String ? eventIdRaw.trim() : '';
    // A stable id is required to make a malformed item safely consumable.
    if (eventId.isEmpty) {
      return const HeartbeatProactiveEventParseResult.fatal();
    }
    final conversationIdRaw = raw['conversation_id'];
    final roleRaw = raw['role'];
    final bodyRaw = raw['body'];
    final createdRaw = raw['created_at'];
    if (conversationIdRaw is! String ||
        roleRaw is! String ||
        bodyRaw is! String ||
        createdRaw is! String) {
      return HeartbeatProactiveEventParseResult.malformedConsumable(seq: seq);
    }
    final conversationId = conversationIdRaw;
    final role = roleRaw;
    final body = bodyRaw;
    final createdAt = DateTime.tryParse(createdRaw);
    if (conversationId != expectedConversationId ||
        role != 'assistant' ||
        body.trim().isEmpty ||
        createdAt == null) {
      return HeartbeatProactiveEventParseResult.malformedConsumable(seq: seq);
    }
    final assistantId = (raw['assistant_id'] ?? '').toString().trim();
    return HeartbeatProactiveEventParseResult.valid(
      HeartbeatProactiveEvent(
        eventId: eventId,
        seq: seq,
        conversationId: conversationId,
        assistantId: assistantId.isEmpty ? null : assistantId,
        createdAt: createdAt,
        body: body,
      ),
    );
  }
}
