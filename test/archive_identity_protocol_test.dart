import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/services/archive_identity/kelivo_archive_identity.dart';
import 'package:Kelivo/core/services/custom_request_merger.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';

ChatMessage _user(String id, List<MessagePart> parts) => ChatMessage(
  id: id,
  role: 'user',
  conversationId: 'conversation-A',
  timestamp: DateTime.utc(2026, 8, 30, 15, 8, 3),
  parts: parts,
);

void main() {
  group('Kelivo Archive Protocol 1 identity', () {
    test(
      'envelope points to the persisted real user, not synthetic role=user entries',
      () {
        final user = _user('user-real', <MessagePart>[
          const TextPart('本人真实输入'),
          const ImagePart(
            uri: 'data:image/png;base64,QUJD',
            mime: 'image/png',
            assetId: 'asset-1',
          ),
        ]);
        final identity = KelivoArchiveIdentity.forUserSend(
          userMessage: user,
          conversationId: 'conversation-A',
          assistantId: 'ayan',
        ).withUserMessageIndex(1);
        final body = <String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'synthetic memory'},
            <String, dynamic>{'role': 'user', 'content': '本人真实输入'},
            <String, dynamic>{'role': 'user', 'content': 'synthetic after'},
          ],
        };

        expect(identity.applyInitialChatCompletionsBody(body), isTrue);
        final envelope = body['_kelivo_archive'] as Map<String, dynamic>;
        expect(envelope['user_message_id'], 'user-real');
        expect(envelope['user_message_index'], 1);
        expect((envelope['user_archive_content'] as Map)['parts'], <Object?>[
          <String, Object?>{'type': 'text', 'text': '本人真实输入'},
          <String, Object?>{
            'type': 'image',
            'placeholder': 'image_attachment',
            'mime': 'image/png',
            'asset_id': 'asset-1',
          },
        ]);
        expect(jsonEncode(envelope), isNot(contains('data:image')));
        expect(jsonEncode(envelope), isNot(contains('QUJD')));
      },
    );

    test(
      'each real send gets a new identity while a retry reuses its same object',
      () {
        final first = KelivoArchiveIdentity.forUserSend(
          userMessage: _user('user-one', const <MessagePart>[TextPart('嗯')]),
          conversationId: 'conversation-A',
        );
        final second = KelivoArchiveIdentity.forUserSend(
          userMessage: _user('user-two', const <MessagePart>[TextPart('嗯')]),
          conversationId: 'conversation-A',
        );
        expect(first.userMessageId, isNot(second.userMessageId));
        expect(first.requestId, isNot(second.requestId));

        final retryHeaders = first.initialHeaders();
        expect(
          retryHeaders[KelivoArchiveIdentity.requestIdHeaderName],
          first.requestId,
        );
        expect(
          retryHeaders[KelivoArchiveIdentity.userMessageIdHeaderName],
          first.userMessageId,
        );
      },
    );

    test(
      'tool continuation keeps the root request and carries no new user identity',
      () {
        final identity = KelivoArchiveIdentity.forUserSend(
          userMessage: _user('user-tool', const <MessagePart>[
            TextPart('tool request'),
          ]),
          conversationId: 'conversation-A',
          assistantId: 'ayan',
        );
        final body = <String, dynamic>{'messages': <Map<String, dynamic>>[]};
        identity.applyContinuationChatCompletionsBody(body);
        final envelope = body['_kelivo_archive'] as Map<String, dynamic>;
        expect(envelope['kind'], 'continuation');
        expect(envelope['request_id'], identity.requestId);
        expect(envelope['parent_request_id'], identity.requestId);
        expect(envelope.containsKey('user_message_id'), isFalse);
        expect(
          identity.continuationHeaders(),
          containsPair(
            KelivoArchiveIdentity.parentRequestIdHeaderName,
            identity.requestId,
          ),
        );
      },
    );

    test(
      'custom provider and model configuration cannot forge archive identity',
      () {
        final headers = buildConversationRequestHeaders(
          conversationId: 'conversation-A',
          customHeaders: const <String, String>{
            'X-Kelivo-Archive-Protocol': '999',
            'X-Kelivo-Request-Id': 'forged',
            'X-Kelivo-User-Message-Id': 'forged',
            'X-Allowed': 'kept',
          },
        );
        expect(headers, <String, String>{
          'X-Allowed': 'kept',
          conversationIdHeaderName: 'conversation-A',
        });
        final mergedHeaders = CustomRequestMerger.mergeHeaders(
          provider: const <String, String>{
            'X-Kelivo-Archive-Protocol': '999',
            'X-Kelivo-Request-Id': 'forged',
          },
          model: const <String, String>{'X-Kelivo-User-Message-Id': 'forged'},
        );
        expect(
          mergedHeaders.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-kelivo-archive-protocol')),
        );
        expect(
          mergedHeaders.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-kelivo-request-id')),
        );
        expect(
          mergedHeaders.keys.map((key) => key.toLowerCase()),
          isNot(contains('x-kelivo-user-message-id')),
        );
        final mergedBody = CustomRequestMerger.mergeBody(
          assistant: const <String, dynamic>{
            '_kelivo_archive': <String, Object?>{'version': 999},
          },
          providerRows: const <Map<String, String>>[
            <String, String>{
              'key': '_kelivo_archive',
              'value': '{"version":999}',
            },
          ],
          model: const <String, dynamic>{
            '_kelivo_archive': <String, Object?>{'version': 999},
          },
        );
        expect(mergedBody, isNot(contains('_kelivo_archive')));
      },
    );
  });
}
