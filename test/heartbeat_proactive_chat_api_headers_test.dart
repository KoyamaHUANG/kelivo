import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_api.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_models.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';
import 'support/collect_generation.dart';

ProviderConfig _config(String baseUrl) => ProviderConfig(
  id: 'provider',
  enabled: true,
  name: 'Arbitrary name',
  apiKey: 'request-key',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  customHeaders: const <Map<String, String>>[
    {'name': 'X-Custom', 'value': 'kept'},
    {'name': 'x-kelivo-conversation-id', 'value': 'must-not-win'},
  ],
);

Future<HttpServer> _server(
  Future<void> Function(HttpRequest request) handler,
) => HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
  server.listen((request) async {
    await handler(request);
  });
  return server;
});

Future<void> _respond(HttpRequest request) async {
  await utf8.decoder.bind(request).join();
  request.response.statusCode = HttpStatus.ok;
  request.response.headers.contentType = ContentType.json;
  request.response.write(
    jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'role': 'assistant', 'content': 'ok'},
          'finish_reason': 'stop',
        },
      ],
      'usage': <String, Object?>{
        'prompt_tokens': 1,
        'completion_tokens': 1,
        'total_tokens': 2,
      },
    }),
  );
  await request.response.close();
}

void main() {
  test(
    'proactive GET uses the shared provider credentials and endpoint',
    () async {
      late HttpHeaders headers;
      late Uri uri;
      final server = await _server((request) async {
        headers = request.headers;
        uri = request.uri;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'object': 'proactive_event_list',
            'conversation_id': 'probe',
            'data': const <Object?>[],
            'next_after_seq': 0,
            'has_more': false,
          }),
        );
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final response = await HttpHeartbeatProactiveApi().fetchEvents(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'model-A',
        conversationId: 'probe',
        afterSeq: 0,
        limit: 1,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(uri.path, '/v1/proactive-events');
      expect(uri.queryParameters, <String, String>{
        'conversation_id': 'probe',
        'after_seq': '0',
        'limit': '1',
      });
      expect(headers.value('authorization'), 'Bearer request-key');
      expect(headers.value('x-custom'), 'kept');
      expect(headers.value(heartbeatConversationHeaderName), isNull);
    },
  );

  test(
    'confirmed Heartbeat headers reach the final chat-completions POST',
    () async {
      late HttpHeaders headers;
      late Uri uri;
      final server = await _server((request) async {
        headers = request.headers;
        uri = request.uri;
        await _respond(request);
      });
      addTearDown(() => server.close(force: true));

      final extraHeaders = buildConversationRequestHeaders(
        conversationId: 'conversation-123',
        customHeaders: const <String, String>{
          'X-Assistant-Custom': 'preserved',
        },
        heartbeatHeaders: const <String, String>{
          heartbeatConversationHeaderName: 'conversation-123',
          heartbeatAssistantHeaderName: 'ayan',
        },
      );
      final chunks = await ChatApiService.sendMessageStream(
        config: _config('http://${server.address.address}:${server.port}/v1'),
        modelId: 'model-A',
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'hello'},
        ],
        extraHeaders: extraHeaders,
        stream: false,
      ).toList();

      expect(chunks.isGenerationDone, isTrue);
      expect(uri.path, '/v1/chat/completions');
      expect(
        headers.value(heartbeatConversationHeaderName),
        'conversation-123',
      );
      expect(headers.value(heartbeatAssistantHeaderName), 'ayan');
      expect(headers.value('authorization'), 'Bearer request-key');
      expect(headers.value('x-custom'), 'kept');
      expect(headers.value('x-assistant-custom'), 'preserved');
    },
  );

  test(
    'ordinary and utility calls have no Heartbeat conversation headers',
    () async {
      final seen = <HttpHeaders>[];
      final server = await _server((request) async {
        seen.add(request.headers);
        await _respond(request);
      });
      addTearDown(() => server.close(force: true));
      final config = _config(
        'http://${server.address.address}:${server.port}/v1',
      );

      await ChatApiService.sendMessageStream(
        config: config,
        modelId: 'model-A',
        messages: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'ordinary'},
        ],
        extraHeaders: buildConversationRequestHeaders(
          conversationId: 'temporary-conversation',
          customHeaders: null,
        ),
        stream: false,
      ).toList();
      await ChatApiService.generateText(
        config: config,
        modelId: 'model-A',
        prompt: 'title utility',
      );

      expect(seen, hasLength(2));
      for (final headers in seen) {
        expect(headers.value(heartbeatConversationHeaderName), isNull);
        expect(headers.value(heartbeatAssistantHeaderName), isNull);
      }
    },
  );
}
