import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/home/services/message_generation_service.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_models.dart';

void main() {
  group('conversation request headers', () {
    test('returns conversation id header when no custom headers', () {
      final headers = buildConversationRequestHeaders(
        conversationId: 'conv-789',
        customHeaders: null,
      );

      expect(headers, {conversationIdHeaderName: 'conv-789'});
    });

    test('adds conversation id header and preserves custom headers', () {
      final headers = buildConversationRequestHeaders(
        conversationId: 'conversation-123',
        customHeaders: const {'X-Gateway': 'EchoPort'},
      );

      expect(headers, {
        'X-Gateway': 'EchoPort',
        conversationIdHeaderName: 'conversation-123',
      });
    });

    test(
      'conversation id header overrides stale custom value after trimming',
      () {
        final headers = buildConversationRequestHeaders(
          conversationId: '  conversation-456  ',
          customHeaders: const {'x-conversation-id': 'old-value'},
        );

        expect(headers, {conversationIdHeaderName: 'conversation-456'});
      },
    );

    test('returns custom headers unchanged when conversation id is blank', () {
      final headers = buildConversationRequestHeaders(
        conversationId: '   ',
        customHeaders: const {'X-Gateway': 'EchoPort'},
      );

      expect(headers, {'X-Gateway': 'EchoPort'});
    });

    test(
      'protects confirmed Heartbeat headers from assistant custom values',
      () {
        final headers = buildConversationRequestHeaders(
          conversationId: 'conversation-123',
          customHeaders: const {
            'X-Kelivo-Conversation-Id': 'stale',
            'x-kelivo-assistant-id': 'stale-assistant',
            'X-Other': 'kept',
          },
          heartbeatHeaders: const {
            heartbeatConversationHeaderName: 'conversation-123',
            heartbeatAssistantHeaderName: 'ayan',
          },
        );

        expect(headers, <String, String>{
          'X-Other': 'kept',
          conversationIdHeaderName: 'conversation-123',
          heartbeatConversationHeaderName: 'conversation-123',
          heartbeatAssistantHeaderName: 'ayan',
        });
      },
    );
  });
}
