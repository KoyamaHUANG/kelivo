import 'package:uuid/uuid.dart';

import '../../models/chat_message.dart';
import '../../models/message_part.dart';

/// Client-owned identity for one persisted, real user-send action.
class KelivoArchiveIdentity {
  KelivoArchiveIdentity._({
    required this.conversationId,
    required this.assistantId,
    required this.requestId,
    required this.userMessageId,
    required this.userMessageTime,
    required this.userArchiveContent,
    required this.userMessageIndex,
  });

  static const int protocolVersion = 1;
  static const String protocolHeaderName = 'X-Kelivo-Archive-Protocol';
  static const String requestIdHeaderName = 'X-Kelivo-Request-Id';
  static const String userMessageIdHeaderName = 'X-Kelivo-User-Message-Id';
  static const String parentRequestIdHeaderName = 'X-Kelivo-Parent-Request-Id';

  final String conversationId;
  final String? assistantId;
  final String requestId;
  final String userMessageId;
  final DateTime userMessageTime;
  final Map<String, dynamic> userArchiveContent;
  final int? userMessageIndex;

  factory KelivoArchiveIdentity.forUserSend({
    required ChatMessage userMessage,
    required String conversationId,
    String? assistantId,
  }) {
    return KelivoArchiveIdentity._(
      conversationId: conversationId,
      assistantId: _optional(assistantId),
      requestId: const Uuid().v4(),
      userMessageId: userMessage.id,
      userMessageTime: userMessage.timestamp.toUtc(),
      userArchiveContent: _safeArchiveContent(userMessage),
      userMessageIndex: null,
    );
  }

  KelivoArchiveIdentity withUserMessageIndex(int? index) =>
      KelivoArchiveIdentity._(
        conversationId: conversationId,
        assistantId: assistantId,
        requestId: requestId,
        userMessageId: userMessageId,
        userMessageTime: userMessageTime,
        userArchiveContent: userArchiveContent,
        userMessageIndex: index,
      );

  Map<String, String> initialHeaders() => <String, String>{
    protocolHeaderName: '$protocolVersion',
    requestIdHeaderName: requestId,
    userMessageIdHeaderName: userMessageId,
  };

  Map<String, String> continuationHeaders() => <String, String>{
    protocolHeaderName: '$protocolVersion',
    requestIdHeaderName: requestId,
    parentRequestIdHeaderName: requestId,
  };

  /// Applies the private envelope after the final HTTP body is assembled.
  /// A later provider mutation may invalidate the index; that fails open.
  bool applyInitialChatCompletionsBody(Map<String, dynamic> body) {
    final index = userMessageIndex;
    final messages = body['messages'];
    if (index == null ||
        index < 0 ||
        messages is! List ||
        index >= messages.length) {
      return false;
    }
    final message = messages[index];
    if (message is! Map || message['role'] != 'user') return false;
    body['_kelivo_archive'] = <String, dynamic>{
      'version': protocolVersion,
      'kind': 'user_send',
      'conversation_id': conversationId,
      if (assistantId != null) 'assistant_id': assistantId,
      'request_id': requestId,
      'user_message_id': userMessageId,
      'user_message_index': index,
      'user_message_time': userMessageTime.toUtc().toIso8601String(),
      'user_archive_content': userArchiveContent,
    };
    return true;
  }

  void applyContinuationChatCompletionsBody(Map<String, dynamic> body) {
    body['_kelivo_archive'] = <String, dynamic>{
      'version': protocolVersion,
      'kind': 'continuation',
      'conversation_id': conversationId,
      if (assistantId != null) 'assistant_id': assistantId,
      'request_id': requestId,
      'parent_request_id': requestId,
    };
  }

  static String? _optional(String? value) {
    final trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Map<String, dynamic> _safeArchiveContent(ChatMessage message) {
    return <String, dynamic>{
      'format': 'kelivo_chat_message_parts_v1',
      'parts': <Map<String, dynamic>>[
        for (final part in message.parts) _safePart(part),
      ],
    };
  }

  static Map<String, dynamic> _safePart(MessagePart part) {
    if (part is TextPart) {
      return <String, dynamic>{'type': 'text', 'text': part.text};
    }
    if (part is ImagePart) {
      return <String, dynamic>{
        'type': 'image',
        'placeholder': 'image_attachment',
        if (part.mime != null) 'mime': part.mime,
        if (part.assetId != null) 'asset_id': part.assetId,
        if (part.unavailable) 'unavailable': true,
      };
    }
    if (part is FilePart) {
      return <String, dynamic>{
        'type': 'file',
        'placeholder': 'file_attachment',
        'name': part.name,
        if (part.mime != null) 'mime': part.mime,
        if (part.assetId != null) 'asset_id': part.assetId,
        if (part.unavailable) 'unavailable': true,
      };
    }
    // Never copy unknown/tool payloads, URIs, or base64 into the envelope.
    return <String, dynamic>{'type': 'opaque', 'kind': part.kind};
  }
}
