import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/message_part.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/archive_identity/kelivo_archive_identity.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_models.dart';
import 'support/collect_generation.dart';

void main() {
  for (final stream in [true, false]) {
    for (final archiveSupported in [true, false]) {
      test(
        'Archive transport stream=$stream capability=$archiveSupported keeps tool root identity',
        () async {
          final requests =
              <({Map<String, dynamic> body, Map<String, String> headers})>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
            final headers = <String, String>{};
            request.headers.forEach(
              (name, values) => headers[name] = values.join(','),
            );
            requests.add((body: body, headers: headers));
            final first = requests.length == 1;
            final message = first
                ? <String, dynamic>{
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        if (stream) 'index': 0,
                        'id': 'call-one',
                        'type': 'function',
                        'function': {
                          'name': 'lookup',
                          'arguments': '{"query":"fixture"}',
                        },
                      },
                    ],
                  }
                : <String, dynamic>{'role': 'assistant', 'content': 'finished'};
            final completion = {
              'id': 'completion-${requests.length}',
              'choices': [
                {
                  'index': 0,
                  stream ? 'delta' : 'message': message,
                  'finish_reason': first ? 'tool_calls' : 'stop',
                },
              ],
            };
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = stream
                ? ContentType('text', 'event-stream', charset: 'utf-8')
                : ContentType.json;
            request.response.write(
              stream
                  ? 'data: ${jsonEncode(completion)}\n\ndata: [DONE]\n\n'
                  : jsonEncode(completion),
            );
            await request.response.close();
          });
          final config = ProviderConfig(
            id: 'transport-fixture',
            enabled: true,
            name: 'Dylan Heartbeat fixture',
            apiKey: '',
            baseUrl: 'http://${server.address.address}:${server.port}/v1',
            providerType: ProviderKind.openai,
            customHeaders: const [
              {'name': 'X-Kelivo-Archive-Protocol', 'value': 'forged'},
              {'name': 'X-Kelivo-Request-Id', 'value': 'forged'},
              {'name': 'X-Kelivo-User-Message-Id', 'value': 'forged'},
              {'name': 'X-Kelivo-Parent-Request-Id', 'value': 'forged'},
            ],
            customBody: const [
              {'key': '_kelivo_archive', 'value': '{"version":999}'},
            ],
          );
          final identity = KelivoArchiveIdentity.forUserSend(
            userMessage: ChatMessage(
              id: 'persisted-real-user',
              conversationId: 'transport-conversation',
              role: 'user',
              timestamp: DateTime.utc(2026, 8, 30),
              parts: const [TextPart('real user')],
            ),
            conversationId: 'transport-conversation',
            assistantId: 'assistant-fixture',
          ).withUserMessageIndex(1);
          const messages = <Map<String, dynamic>>[
            {'role': 'user', 'content': 'synthetic memory'},
            {'role': 'user', 'content': 'real user'},
          ];
          const tools = <Map<String, dynamic>>[
            {
              'type': 'function',
              'function': {
                'name': 'lookup',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'},
                  },
                },
              },
            },
          ];
          const proactiveHeaders = {
            heartbeatConversationHeaderName: 'transport-conversation',
            heartbeatAssistantHeaderName: 'assistant-fixture',
          };
          var calls = 0;
          Future<String> onToolCall(
            String name,
            Map<String, dynamic> args, {
            String? toolCallId,
          }) async {
            calls++;
            expect(name, 'lookup');
            expect(args, {'query': 'fixture'});
            expect(toolCallId, 'call-one');
            return 'fixture-result';
          }

          if (stream) {
            final chunks = await ChatApiService.sendMessageStream(
              config: config,
              modelId: 'fixture-model',
              messages: messages,
              tools: tools,
              onToolCall: onToolCall,
              extraHeaders: proactiveHeaders,
              archiveIdentity: archiveSupported ? identity : null,
            ).toList();
            expect(chunks.isGenerationDone, isTrue);
          } else {
            await ChatApiService.generateMessage(
              config: config,
              modelId: 'fixture-model',
              messages: messages,
              tools: tools,
              onToolCall: onToolCall,
              extraHeaders: proactiveHeaders,
              archiveIdentity: archiveSupported ? identity : null,
            );
          }
          expect(calls, 1);
          expect(requests, hasLength(2));
          for (final request in requests) {
            expect(
              request.headers['x-kelivo-conversation-id'],
              'transport-conversation',
            );
            expect(
              request.headers['x-kelivo-assistant-id'],
              'assistant-fixture',
            );
            if (archiveSupported) {
              expect(request.headers['x-kelivo-archive-protocol'], '1');
              expect(
                request.headers['x-kelivo-request-id'],
                identity.requestId,
              );
              expect(
                (request.body['_kelivo_archive'] as Map)['request_id'],
                identity.requestId,
              );
            } else {
              expect(
                request.headers.keys.where(
                  (key) =>
                      key.startsWith('x-kelivo-') &&
                      ![
                        'x-kelivo-conversation-id',
                        'x-kelivo-assistant-id',
                      ].contains(key),
                ),
                isEmpty,
              );
              expect(request.body, isNot(contains('_kelivo_archive')));
            }
          }
          if (archiveSupported) {
            final first = requests.first;
            expect(
              first.headers['x-kelivo-user-message-id'],
              identity.userMessageId,
            );
            expect(first.headers['x-kelivo-parent-request-id'], isNull);
            expect((first.body['_kelivo_archive'] as Map)['kind'], 'user_send');
            expect(
              (first.body['_kelivo_archive'] as Map)['user_message_index'],
              1,
            );
            final followUp = requests.last;
            expect(
              followUp.headers['x-kelivo-parent-request-id'],
              identity.requestId,
            );
            expect(followUp.headers['x-kelivo-user-message-id'], isNull);
            final envelope = followUp.body['_kelivo_archive'] as Map;
            expect(envelope['kind'], 'continuation');
            expect(envelope['parent_request_id'], identity.requestId);
            expect(envelope, isNot(contains('user_message_id')));
          }
          expect(
            (requests.last.body['messages'] as List).where(
              (message) => message['role'] == 'tool',
            ),
            hasLength(1),
          );
        },
      );
    }
  }
}
