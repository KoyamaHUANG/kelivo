import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/business_test_harness.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_api.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_models.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_store.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_sync_service.dart';

class _Call {
  const _Call({
    required this.config,
    required this.modelId,
    required this.conversationId,
    required this.afterSeq,
    required this.limit,
    required this.assistantId,
  });

  final ProviderConfig config;
  final String modelId;
  final String conversationId;
  final int afterSeq;
  final int limit;
  final String? assistantId;
}

class _FakeApi implements HeartbeatProactiveApi {
  _FakeApi(this.handler);

  final FutureOr<HeartbeatProactiveHttpResponse> Function(_Call call) handler;
  final calls = <_Call>[];

  @override
  Future<HeartbeatProactiveHttpResponse> fetchEvents({
    required ProviderConfig config,
    required String modelId,
    required String conversationId,
    required int afterSeq,
    required int limit,
    String? assistantId,
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    final call = _Call(
      config: config,
      modelId: modelId,
      conversationId: conversationId,
      afterSeq: afterSeq,
      limit: limit,
      assistantId: assistantId,
    );
    calls.add(call);
    return handler(call);
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

class _FailingChatService extends ChatService {
  _FailingChatService({required super.existingRepository});

  String? failMessageId;

  @override
  Future<bool> appendExternalAssistantMessage(ChatMessage message) {
    if (message.id == failMessageId) {
      return Future<bool>.error(StateError('simulated database failure'));
    }
    return super.appendExternalAssistantMessage(message);
  }
}

ProviderConfig _config({
  String id = 'heartbeat-provider',
  String baseUrl = 'https://heartbeat.example/v1',
  String? chatPath,
}) => ProviderConfig(
  id: id,
  enabled: true,
  name: 'Any user chosen name',
  apiKey: 'not-persisted',
  baseUrl: baseUrl,
  providerType: ProviderKind.openai,
  chatPath: chatPath,
);

Map<String, Object?> _event(
  int seq,
  String id,
  String conversationId, {
  String body = 'proactive',
  String role = 'assistant',
  String createdAt = '2026-08-22T10:00:00.000Z',
}) => <String, Object?>{
  'event_id': id,
  'seq': seq,
  'conversation_id': conversationId,
  'assistant_id': 'ayan',
  'created_at': createdAt,
  'role': role,
  'body': body,
  'unknown_future_field': true,
};

HeartbeatProactiveHttpResponse _page(
  String conversationId,
  List<Object?> data, {
  required int nextAfterSeq,
  bool hasMore = false,
}) => HeartbeatProactiveHttpResponse(
  statusCode: 200,
  body: <String, Object?>{
    'object': 'proactive_event_list',
    'conversation_id': conversationId,
    'data': data,
    'next_after_seq': nextAfterSeq,
    'oldest_seq': 1,
    'latest_seq': nextAfterSeq,
    'has_more': hasMore,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ChatDatabaseRepository repository;
  late ChatService chatService;
  late PathProviderPlatform previousPathProvider;
  late BusinessPreferences businessPreferences;
  late HeartbeatProactiveStore store;

  setUp(() async {
    businessPreferences = createBusinessTestPreferences();
    await businessPreferences.load();
    store = HeartbeatProactiveStore(preferences: businessPreferences);
    directory = await Directory.systemTemp.createTemp('kelivo_heartbeat_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(directory.path);
    repository = ChatDatabaseRepository.open(
      file: File('${directory.path}/kelivo.db'),
    );
    await repository.ensureReady();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await chatService.close();
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('endpoint and event parsing', () {
    test('normalizes root and v1 base URLs without duplicate v1', () {
      for (final raw in <String>[
        'https://x.com',
        'https://x.com/',
        'https://x.com/v1',
        'https://x.com/v1/',
      ]) {
        expect(
          buildHeartbeatProactiveEventsEndpoint(
            _config(baseUrl: raw),
          ).toString(),
          'https://x.com/v1/proactive-events',
        );
      }
    });

    test('derives version prefix from a separately configured chat path', () {
      expect(
        buildHeartbeatProactiveEventsEndpoint(
          _config(
            baseUrl: 'https://x.com',
            chatPath: '/edge/v1/chat/completions',
          ),
        ).toString(),
        'https://x.com/edge/v1/proactive-events',
      );
    });

    test('parses unknown fields but consumes safely malformed events', () {
      final parsed = HeartbeatProactivePage.tryParse(
        _page('conversation-A', <Object?>[
          _event(4, 'good', 'conversation-A'),
          _event(1, 'wrong-role', 'conversation-A', role: 'user'),
          <String, Object?>{
            'event_id': 'missing-body',
            'seq': 2,
            'conversation_id': 'conversation-A',
            'role': 'assistant',
            'created_at': '2026-08-22T10:00:00.000Z',
          },
          _event(
            3,
            'bad-timestamp',
            'conversation-A',
            createdAt: 'not-a-timestamp',
          ),
        ], nextAfterSeq: 4).body,
        expectedConversationId: 'conversation-A',
      );

      expect(parsed, isNotNull);
      expect(
        parsed!.events.map((item) => item.seq),
        orderedEquals(<int>[1, 2, 3, 4]),
      );
      expect(
        parsed.events.take(3).map((item) => item.kind),
        everyElement(HeartbeatProactiveEventParseKind.malformedConsumable),
      );
      expect(parsed.events.last.event!.body, 'proactive');
      expect(
        HeartbeatProactivePage.tryParse(<String, Object?>{
          'object': 'proactive_event_list',
          'conversation_id': 'conversation-A',
          'data': <Object?>[
            <String, Object?>{'event_id': 'x', 'seq': 'not-an-int'},
          ],
          'next_after_seq': 0,
          'has_more': false,
        }, expectedConversationId: 'conversation-A'),
        isNull,
      );
    });
  });

  group('shared generation archive identity', () {
    Future<HeartbeatProactiveSyncService> identityService() async {
      final api = _FakeApi(
        (call) => HeartbeatProactiveHttpResponse(
          statusCode: 200,
          body: <String, Object?>{
            'object': 'proactive_event_list',
            'conversation_id': call.conversationId,
            'data': const <Object?>[],
            'next_after_seq': 0,
            'has_more': false,
            'capabilities': const <String, Object?>{
              'archive_identity_protocol': 1,
            },
          },
        ),
      );
      return HeartbeatProactiveSyncService(
        chatService: chatService,
        store: store,
        api: api,
      );
    }

    test(
      'normal send, regenerate, manual recovery and store recreation reuse the real root',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final user = ChatMessage(
          id: 'fixture-user',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture',
          timestamp: DateTime.utc(2026, 7, 6),
        );
        final sync = await identityService();
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        final first = await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: user,
          allowNewRequest: true,
        );
        expect(first, isNotNull);
        for (final operation in ['regenerate', 'manual recovery', 'retry']) {
          final replay = await sync.archiveIdentityForGeneration(
            preparation: prep,
            conversation: conversation,
            config: _config(),
            userMessage: user,
            allowNewRequest: false,
          );
          expect(replay!.requestId, first!.requestId, reason: operation);
          expect(replay.userMessageId, user.id);
          expect(replay.userMessageTime, user.timestamp.toUtc());
          final body = <String, dynamic>{
            'messages': [
              <String, dynamic>{'role': 'user', 'content': 'fixture'},
            ],
          };
          expect(
            replay
                .withUserMessageIndex(0)
                .applyInitialChatCompletionsBody(body),
            isTrue,
          );
          expect(
            (body['_kelivo_archive'] as Map)['request_id'],
            first.requestId,
          );
          expect(
            prep.headers![heartbeatConversationHeaderName],
            conversation.id,
          );
          expect(
            prep.headers![heartbeatAssistantHeaderName],
            replay.assistantId,
          );
        }
        final reopened = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: HeartbeatProactiveStore(preferences: businessPreferences),
          api: _FakeApi((_) => throw StateError('should not probe')),
        );
        final recovered = await reopened.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: user,
          allowNewRequest: false,
        );
        expect(recovered!.requestId, first!.requestId);
        final persisted = businessPreferences
            .getKeys()
            .where((key) => key.startsWith('heartbeat_archive_request_v1:'))
            .toList();
        expect(persisted, hasLength(1));
        expect(
          businessPreferences.getString(persisted.single),
          first.requestId,
        );
      },
    );

    test(
      'edited user revision gets its own root and subsequent regeneration keeps it',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final sync = await identityService();
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        final original = ChatMessage(
          id: 'fixture-user-v0',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture',
          groupId: 'fixture-group',
          version: 0,
        );
        final edited = original.copyWith(
          id: 'fixture-user-v1',
          content: 'edited fixture',
          version: 1,
        );
        final first = await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: original,
          allowNewRequest: true,
        );
        final edit = await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: edited,
          allowNewRequest: true,
        );
        final replay = await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: edited,
          allowNewRequest: false,
        );
        expect(edit!.requestId, isNot(first!.requestId));
        expect(edit.userMessageId, edited.id);
        expect(replay!.requestId, edit.requestId);
      },
    );

    test(
      'legacy recovery never invents a parent or a new root for an already sent message',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final sync = await identityService();
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        final user = ChatMessage(
          id: 'fixture-old',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture',
        );
        await expectLater(
          sync.archiveIdentityForGeneration(
            preparation: prep,
            conversation: conversation,
            config: _config(),
            userMessage: user,
            allowNewRequest: false,
          ),
          throwsStateError,
        );
        expect(
          businessPreferences.getKeys().where(
            (key) => key.startsWith('heartbeat_archive_request_v1:'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'cross-conversation messages and provider endpoint switches cannot reuse another scope',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final sync = await identityService();
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        final user = ChatMessage(
          id: 'fixture-user',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture',
        );
        await expectLater(
          sync.archiveIdentityForGeneration(
            preparation: prep,
            conversation: conversation,
            config: _config(),
            userMessage: user.copyWith(conversationId: 'other'),
            allowNewRequest: true,
          ),
          throwsStateError,
        );
        await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: _config(),
          userMessage: user,
          allowNewRequest: true,
        );
        await expectLater(
          sync.archiveIdentityForGeneration(
            preparation: prep,
            conversation: conversation,
            config: _config(baseUrl: 'https://other.example/v1'),
            userMessage: user,
            allowNewRequest: false,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'regeneration capability check skips proactive pull and binding writes',
      () async {
        final conversation = await chatService.createConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final calls = <String>[];
        final api = _FakeApi((call) {
          calls.add(call.conversationId);
          return HeartbeatProactiveHttpResponse(
            statusCode: 200,
            body: <String, Object?>{
              'object': 'proactive_event_list',
              'data': const <Object?>[],
              'capabilities': const <String, Object?>{
                'archive_identity_protocol': 1,
              },
            },
          );
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        expect(prep.supportsArchiveIdentityProtocol, isTrue);
        expect(calls, ['__kelivo_capability_probe__']);
        expect(await store.getBinding(conversation.id), isNull);
      },
    );

    test(
      'archive capability survives a proactive-only downgrade during normal send',
      () async {
        final conversation = await chatService.createConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final api = _FakeApi(
          (call) => call.conversationId == '__kelivo_capability_probe__'
              ? HeartbeatProactiveHttpResponse(
                  statusCode: 200,
                  body: <String, Object?>{
                    'object': 'proactive_event_list',
                    'data': const <Object?>[],
                    'capabilities': const <String, Object?>{
                      'archive_identity_protocol': 1,
                    },
                  },
                )
              : const HeartbeatProactiveHttpResponse(
                  statusCode: 404,
                  body: <String, Object?>{},
                ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        expect(prep.supportsArchiveIdentityProtocol, isTrue);
        expect(
          prep.headers![heartbeatAssistantHeaderName],
          'fixture-assistant',
        );
      },
    );

    test(
      'stored request scope excludes URL credentials, query keys, fragments and message text',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
          assistantId: 'fixture-assistant',
        );
        final sync = await identityService();
        final config = _config(
          baseUrl:
              'https://fixture-login:fixture-password@heartbeat.example/v1?api_key=fixture-query#fixture-fragment',
        );
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: config,
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        final user = ChatMessage(
          id: 'fixture-user',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture-private-content',
        );
        await sync.archiveIdentityForGeneration(
          preparation: prep,
          conversation: conversation,
          config: config,
          userMessage: user,
          allowNewRequest: true,
        );
        final key = businessPreferences.getKeys().singleWhere(
          (key) => key.startsWith('heartbeat_archive_request_v1:'),
        );
        final scope = utf8.decode(base64Url.decode(key.split(':')[1]));
        for (final sensitive in [
          'fixture-login',
          'fixture-password',
          'fixture-query',
          'fixture-fragment',
          'fixture-private-content',
        ]) {
          expect(scope, isNot(contains(sensitive)));
        }
      },
    );

    test(
      'unconfirmed capability and unbound assistant do not gain a private identity',
      () async {
        final conversation = await chatService.createDraftConversation(
          title: 'fixture',
        );
        final sync = await identityService();
        final user = ChatMessage(
          id: 'fixture-user',
          role: 'user',
          conversationId: conversation.id,
          content: 'fixture',
        );
        expect(
          await sync.archiveIdentityForGeneration(
            preparation: HeartbeatProactiveChatPreparation.none,
            conversation: conversation,
            config: _config(),
            userMessage: user,
            allowNewRequest: true,
          ),
          isNull,
        );
        final prep = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          syncBeforeSend: false,
        );
        expect(
          await sync.archiveIdentityForGeneration(
            preparation: prep,
            conversation: conversation,
            config: _config(),
            userMessage: user,
            allowNewRequest: true,
          ),
          isNull,
        );
      },
    );
  });

  group('capability and binding', () {
    test(
      'positive capability is cached by provider id and normalized base URL',
      () async {
        final api = _FakeApi(
          (_) => _page(
            '__kelivo_capability_probe__',
            const <Object?>[],
            nextAfterSeq: 0,
          ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        expect(
          await sync.supportsProactiveSync(config: _config(), modelId: 'model'),
          isTrue,
        );
        expect(
          await sync.supportsProactiveSync(config: _config(), modelId: 'model'),
          isTrue,
        );
        expect(api.calls, hasLength(1));
        expect(
          await sync.supportsProactiveSync(
            config: _config(baseUrl: 'https://heartbeat.example/v1-alt'),
            modelId: 'model',
          ),
          isTrue,
        );
        expect(api.calls, hasLength(2));
      },
    );

    test(
      '404 and timeout are negative only for the current service session',
      () async {
        final first = _FakeApi(
          (_) =>
              const HeartbeatProactiveHttpResponse(statusCode: 404, body: null),
        );
        final firstService = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: first,
        );
        expect(
          await firstService.supportsProactiveSync(
            config: _config(),
            modelId: 'model',
          ),
          isFalse,
        );
        expect(
          await firstService.supportsProactiveSync(
            config: _config(),
            modelId: 'model',
          ),
          isFalse,
        );
        expect(first.calls, hasLength(1));

        final second = _FakeApi(
          (_) => _page(
            '__kelivo_capability_probe__',
            const <Object?>[],
            nextAfterSeq: 0,
          ),
        );
        final restarted = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: second,
        );
        expect(
          await restarted.supportsProactiveSync(
            config: _config(),
            modelId: 'model',
          ),
          isTrue,
        );
        expect(second.calls, hasLength(1));
      },
    );

    test(
      'only real persistent conversations gain binding and dynamic headers',
      () async {
        final conversation = await chatService.createConversation(
          title: 'A',
          assistantId: 'ayan',
        );
        final api = _FakeApi((call) {
          if (call.conversationId == '__kelivo_capability_probe__') {
            return _page(
              call.conversationId,
              const <Object?>[],
              nextAfterSeq: 0,
            );
          }
          return _page(call.conversationId, const <Object?>[], nextAfterSeq: 0);
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        expect(preparation.headers, <String, String>{
          heartbeatConversationHeaderName: conversation.id,
          heartbeatAssistantHeaderName: 'ayan',
        });
        final binding = await store.getBinding(conversation.id);
        expect(binding, isNotNull);
        expect(binding!.modelId, 'model-A');

        final temporary = await chatService.createDraftConversation(
          title: 'temporary',
          temporary: true,
        );
        expect(
          (await sync.prepareForUserChat(
            conversation: temporary,
            config: _config(),
            providerId: 'heartbeat-provider',
            modelId: 'model-A',
          )).headers,
          isNull,
        );
        expect(await store.getBinding(temporary.id), isNull);
      },
    );

    test(
      'a definitive sync downgrade clears capability before chat headers',
      () async {
        final conversation = await chatService.createConversation(title: 'A');
        final api = _FakeApi((call) {
          if (call.conversationId == '__kelivo_capability_probe__') {
            return _page(
              call.conversationId,
              const <Object?>[],
              nextAfterSeq: 0,
            );
          }
          return const HeartbeatProactiveHttpResponse(
            statusCode: 404,
            body: null,
          );
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );

        expect(preparation.headers, isNull);
        expect(
          await store.hasPositiveCapability(
            heartbeatProviderIdentity(
              'heartbeat-provider',
              normalizeHeartbeatBaseUrl(_config().baseUrl),
            ),
          ),
          isFalse,
        );
      },
    );

    test('independent device stores keep independent cursors', () async {
      final secondPreferences = createBusinessTestPreferences();
      await secondPreferences.load();
      final secondStore = HeartbeatProactiveStore(
        preferences: secondPreferences,
      );
      const binding = HeartbeatProactiveBinding(
        conversationId: 'conversation-A',
        providerId: 'heartbeat-provider',
        modelId: 'model-A',
        assistantId: null,
        normalizedBaseUrl: 'https://heartbeat.example/v1',
      );

      expect(await store.getCursor(binding), 0);
      expect(await secondStore.getCursor(binding), 0);
      await store.setCursor(binding, 12);
      expect(await store.getCursor(binding), 12);
      expect(await secondStore.getCursor(binding), 0);
      await secondStore.setCursor(binding, 12);
      expect(await secondStore.getCursor(binding), 12);
    });
  });

  group('durable sync semantics', () {
    test(
      'Archive cache starts absent and is isolated by provider ID and base URL',
      () async {
        final first = _config(id: 'first');
        final firstScope = heartbeatProviderIdentity(
          first.id,
          normalizeHeartbeatBaseUrl(first.baseUrl),
        );
        expect(
          await store.getArchiveIdentityProtocolVersion(firstScope),
          isNull,
        );
        final api = _FakeApi(
          (call) => HeartbeatProactiveHttpResponse(
            statusCode: 200,
            body: {
              'object': 'proactive_event_list',
              'conversation_id': call.conversationId,
              'data': <Object?>[],
              'next_after_seq': 0,
              'has_more': false,
              'capabilities': {
                'archive_identity_protocol':
                    call.config.id == 'first' &&
                        call.config.baseUrl == first.baseUrl
                    ? 1
                    : 0,
              },
            },
          ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        expect(
          (await sync.gatewayCapabilities(
            config: first,
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isTrue,
        );
        expect(
          (await sync.gatewayCapabilities(
            config: _config(id: 'second'),
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isFalse,
        );
        expect(
          (await sync.gatewayCapabilities(
            config: _config(id: 'first', baseUrl: 'https://other.example/v1'),
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isFalse,
        );
        final restarted = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: HeartbeatProactiveStore(preferences: businessPreferences),
          api: api,
        );
        expect(
          (await restarted.gatewayCapabilities(
            config: first,
            modelId: 'model-B',
          )).supportsArchiveIdentityProtocol,
          isTrue,
        );
        expect(api.calls, hasLength(3));
        expect(await store.getArchiveIdentityProtocolVersion(firstScope), 1);
      },
    );

    test(
      'Proactive-only cached capability is probed for Archive on upgrade',
      () async {
        final config = _config();
        final scope = heartbeatProviderIdentity(
          config.id,
          normalizeHeartbeatBaseUrl(config.baseUrl),
        );
        await store.setPositiveCapability(scope);
        expect(await store.getArchiveIdentityProtocolVersion(scope), isNull);
        final api = _FakeApi(
          (call) => HeartbeatProactiveHttpResponse(
            statusCode: 200,
            body: {
              'object': 'proactive_event_list',
              'capabilities': {'archive_identity_protocol': 1},
            },
          ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        expect(
          (await sync.gatewayCapabilities(
            config: config,
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isTrue,
        );
        expect(api.calls, hasLength(1));
        expect(await store.getArchiveIdentityProtocolVersion(scope), 1);
      },
    );

    test(
      'failed capability probe never writes a completed zero capability',
      () async {
        final config = _config();
        final scope = heartbeatProviderIdentity(
          config.id,
          normalizeHeartbeatBaseUrl(config.baseUrl),
        );
        final api = _FakeApi(
          (call) => throw const SocketException('fixture offline'),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        expect(
          (await sync.gatewayCapabilities(
            config: config,
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isFalse,
        );
        expect(await store.getArchiveIdentityProtocolVersion(scope), isNull);
        expect(await store.hasPositiveCapability(scope), isFalse);
      },
    );

    test(
      'Proactive endpoint without Archive advertisement remains Proactive-only',
      () async {
        final conversation = await chatService.createConversation(
          title: 'fixture',
          assistantId: 'ayan',
        );
        final api = _FakeApi(
          (call) => _page(call.conversationId, [], nextAfterSeq: 0),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        expect(preparation.supportsArchiveIdentityProtocol, isFalse);
        expect(preparation.headers, {
          heartbeatConversationHeaderName: conversation.id,
          heartbeatAssistantHeaderName: 'ayan',
        });
        expect(await store.getBinding(conversation.id), isNotNull);
      },
    );

    test(
      'Responses retains baseline Proactive support but never gets Archive identity',
      () async {
        final conversation = await chatService.createConversation(
          title: 'fixture',
          assistantId: 'ayan',
        );
        final config = _config().copyWith(useResponseApi: true);
        final api = _FakeApi(
          (call) => HeartbeatProactiveHttpResponse(
            statusCode: 200,
            body: {
              'object': 'proactive_event_list',
              'conversation_id': call.conversationId,
              'data': <Object?>[],
              'next_after_seq': 0,
              'has_more': false,
              'capabilities': {'archive_identity_protocol': 1},
            },
          ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: config,
          providerId: config.id,
          modelId: 'model-A',
        );
        expect(preparation.supportsArchiveIdentityProtocol, isFalse);
        expect(
          preparation.headers?[heartbeatConversationHeaderName],
          conversation.id,
        );
        expect(await store.getBinding(conversation.id), isNotNull);
        expect(
          (await sync.gatewayCapabilities(
            config: config.copyWith(useResponseApi: false),
            modelId: 'model-A',
          )).supportsArchiveIdentityProtocol,
          isTrue,
        );
      },
    );

    test(
      'native providers neither probe nor inherit an OpenAI Archive cache',
      () async {
        final config = _config();
        final scope = heartbeatProviderIdentity(
          config.id,
          normalizeHeartbeatBaseUrl(config.baseUrl),
        );
        await store.setPositiveCapability(scope);
        await store.setArchiveIdentityProtocolVersion(scope, 1);
        final api = _FakeApi((call) => throw StateError('must not probe'));
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        for (final kind in [ProviderKind.claude, ProviderKind.google]) {
          final capability = await sync.gatewayCapabilities(
            config: config.copyWith(providerType: kind),
            modelId: 'model-A',
          );
          expect(capability.proactiveSync, isFalse);
          expect(capability.supportsArchiveIdentityProtocol, isFalse);
        }
        expect(api.calls, isEmpty);
      },
    );

    group('archive identity capability', () {
      test(
        'new non-persisted conversations get Protocol 1 headers without a proactive binding',
        () async {
          final draft = await chatService.createDraftConversation(
            title: 'first send',
            assistantId: 'ayan',
          );
          final api = _FakeApi(
            (call) => HeartbeatProactiveHttpResponse(
              statusCode: 200,
              body: <String, Object?>{
                'object': 'proactive_event_list',
                'conversation_id': call.conversationId,
                'data': const <Object?>[],
                'next_after_seq': 0,
                'has_more': false,
                'capabilities': const <String, Object?>{
                  'archive_identity_protocol': 1,
                },
              },
            ),
          );
          final sync = HeartbeatProactiveSyncService(
            chatService: chatService,
            store: store,
            api: api,
          );

          final preparation = await sync.prepareForUserChat(
            conversation: draft,
            config: _config(),
            providerId: 'heartbeat-provider',
            modelId: 'model-A',
          );

          expect(preparation.supportsArchiveIdentityProtocol, isTrue);
          expect(preparation.headers, <String, String>{
            heartbeatConversationHeaderName: draft.id,
            heartbeatAssistantHeaderName: 'ayan',
          });
          expect(await store.getBinding(draft.id), isNull);
        },
      );
    });

    test(
      'pre-send sync publishes proactive assistant before the user reply',
      () async {
        final conversation = await chatService.createConversation(
          title: 'A',
          assistantId: 'ayan',
        );
        final published = <ChatMessage>[];
        var notifications = 0;
        chatService.addListener(() => notifications++);
        final api = _FakeApi((call) {
          if (call.conversationId == '__kelivo_capability_probe__') {
            return _page(
              call.conversationId,
              const <Object?>[],
              nextAfterSeq: 0,
            );
          }
          return _page(call.conversationId, <Object?>[
            _event(7, 'before-reply', call.conversationId, body: '先收到的主动消息'),
          ], nextAfterSeq: 7);
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
          onMessagesPersisted: (messages) async {
            published.addAll(messages);
          },
        );

        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        await chatService.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: '刚忙完',
        );

        expect(
          preparation.headers![heartbeatConversationHeaderName],
          conversation.id,
        );
        expect(published.map((message) => message.id), <String>[
          'heartbeat:before-reply',
        ]);
        expect(notifications, greaterThan(0));
        expect(
          (await chatService.loadMessages(
            conversation.id,
          )).map((message) => message.content),
          <String>['先收到的主动消息', '刚忙完'],
        );
      },
    );

    test(
      'pre-send timeout still returns headers and leaves normal chat usable',
      () async {
        final conversation = await chatService.createConversation(title: 'A');
        final stalled = Completer<HeartbeatProactiveHttpResponse>();
        final api = _FakeApi((call) {
          if (call.conversationId == '__kelivo_capability_probe__') {
            return _page(
              call.conversationId,
              const <Object?>[],
              nextAfterSeq: 0,
            );
          }
          return stalled.future;
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );
        final stopwatch = Stopwatch()..start();

        final preparation = await sync.prepareForUserChat(
          conversation: conversation,
          config: _config(),
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
        );
        stopwatch.stop();
        await chatService.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'send despite sync outage',
        );

        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
        expect(
          preparation.headers![heartbeatConversationHeaderName],
          conversation.id,
        );
        expect(
          (await chatService.loadMessages(conversation.id)).single.content,
          'send despite sync outage',
        );
      },
    );

    test(
      'writes a real idempotent assistant message without touching updatedAt',
      () async {
        final conversation = await chatService.createConversation(title: 'A');
        final originalUpdatedAt = conversation.updatedAt;
        final binding = HeartbeatProactiveBinding(
          conversationId: conversation.id,
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          assistantId: null,
          normalizedBaseUrl: normalizeHeartbeatBaseUrl(_config().baseUrl),
        );
        final api = _FakeApi(
          (call) => _page(call.conversationId, <Object?>[
            _event(1, 'abc', call.conversationId, body: '想你了，在忙吗？'),
          ], nextAfterSeq: 1),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        await sync.syncBinding(binding, config: _config());
        final restarted = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: HeartbeatProactiveStore(preferences: businessPreferences),
          api: api,
        );
        await restarted.syncBinding(binding, config: _config());
        final messages = await chatService.loadMessages(conversation.id);
        expect(messages, hasLength(1));
        expect(messages.single.id, 'heartbeat:abc');
        expect(messages.single.role, 'assistant');
        expect(messages.single.content, '想你了，在忙吗？');
        expect(messages.single.conversationId, conversation.id);
        expect(messages.single.providerId, 'heartbeat-provider');
        expect(messages.single.modelId, 'model-A');
        expect(messages.single.isStreaming, isFalse);
        expect(
          chatService.getConversation(conversation.id)!.updatedAt,
          originalUpdatedAt,
        );
        expect(await store.getCursor(binding), 1);
      },
    );

    test('does not advance past a failed write, then resumes safely', () async {
      await chatService.close();
      chatService = _FailingChatService(existingRepository: repository);
      await chatService.init();
      final conversation = await chatService.createConversation(title: 'A');
      final binding = HeartbeatProactiveBinding(
        conversationId: conversation.id,
        providerId: 'heartbeat-provider',
        modelId: 'model-A',
        assistantId: null,
        normalizedBaseUrl: normalizeHeartbeatBaseUrl(_config().baseUrl),
      );
      final api = _FakeApi(
        (call) => _page(call.conversationId, <Object?>[
          for (final seq in <int>[1, 2, 3])
            _event(seq, 'event-$seq', call.conversationId),
        ], nextAfterSeq: 3),
      );
      final sync = HeartbeatProactiveSyncService(
        chatService: chatService,
        store: store,
        api: api,
      );
      (chatService as _FailingChatService).failMessageId = 'heartbeat:event-2';

      await sync.syncBinding(binding, config: _config());
      expect(await store.getCursor(binding), 1);
      expect(
        (await chatService.loadMessages(conversation.id)).map((m) => m.id),
        <String>['heartbeat:event-1'],
      );

      (chatService as _FailingChatService).failMessageId = null;
      await sync.syncBinding(binding, config: _config());
      expect(await store.getCursor(binding), 3);
      expect(
        (await chatService.loadMessages(conversation.id)).map((m) => m.id),
        <String>['heartbeat:event-1', 'heartbeat:event-2', 'heartbeat:event-3'],
      );
    });

    test(
      'consumes malformed body but imports later valid events in seq order',
      () async {
        final conversation = await chatService.createConversation(title: 'A');
        final binding = HeartbeatProactiveBinding(
          conversationId: conversation.id,
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          assistantId: null,
          normalizedBaseUrl: normalizeHeartbeatBaseUrl(_config().baseUrl),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: _FakeApi(
            (call) => _page(call.conversationId, <Object?>[
              _event(2, 'second', call.conversationId, body: 'second'),
              _event(1, 'bad', call.conversationId, body: ''),
              _event(3, 'third', call.conversationId, body: 'third'),
            ], nextAfterSeq: 3),
          ),
        );

        await sync.syncBinding(binding, config: _config());
        expect(await store.getCursor(binding), 3);
        expect(
          (await chatService.loadMessages(
            conversation.id,
          )).map((m) => m.content),
          <String>['second', 'third'],
        );
      },
    );

    test(
      'conversation bindings never write an event into another chat',
      () async {
        final conversationA = await chatService.createConversation(title: 'A');
        final conversationB = await chatService.createConversation(title: 'B');
        HeartbeatProactiveBinding bindingFor(Conversation conversation) =>
            HeartbeatProactiveBinding(
              conversationId: conversation.id,
              providerId: 'heartbeat-provider',
              modelId: 'model-A',
              assistantId: null,
              normalizedBaseUrl: normalizeHeartbeatBaseUrl(_config().baseUrl),
            );
        final api = _FakeApi(
          (call) => _page(
            call.conversationId,
            <Object?>[
              _event(
                call.conversationId == conversationA.id ? 5 : 20,
                call.conversationId == conversationA.id ? 'event-A' : 'event-B',
                call.conversationId,
                body: call.conversationId == conversationA.id
                    ? 'for A'
                    : 'for B',
              ),
            ],
            nextAfterSeq: call.conversationId == conversationA.id ? 5 : 20,
          ),
        );
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        await sync.syncBinding(bindingFor(conversationA), config: _config());
        expect(
          (await chatService.loadMessages(
            conversationA.id,
          )).map((message) => message.content),
          <String>['for A'],
        );
        expect(await chatService.loadMessages(conversationB.id), isEmpty);

        await sync.syncBinding(bindingFor(conversationB), config: _config());
        expect(
          (await chatService.loadMessages(
            conversationB.id,
          )).map((message) => message.content),
          <String>['for B'],
        );
      },
    );

    test(
      'paginates and coalesces concurrent sync triggers per binding',
      () async {
        final conversation = await chatService.createConversation(title: 'A');
        final binding = HeartbeatProactiveBinding(
          conversationId: conversation.id,
          providerId: 'heartbeat-provider',
          modelId: 'model-A',
          assistantId: null,
          normalizedBaseUrl: normalizeHeartbeatBaseUrl(_config().baseUrl),
        );
        final firstResponse = Completer<HeartbeatProactiveHttpResponse>();
        final api = _FakeApi((call) {
          if (call.afterSeq == 0) return firstResponse.future;
          return _page(call.conversationId, <Object?>[
            _event(2, 'second', call.conversationId, body: 'second'),
          ], nextAfterSeq: 2);
        });
        final sync = HeartbeatProactiveSyncService(
          chatService: chatService,
          store: store,
          api: api,
        );

        final one = sync.syncBinding(binding, config: _config());
        final two = sync.syncBinding(binding, config: _config());
        await Future<void>.delayed(Duration.zero);
        expect(api.calls, hasLength(1));
        firstResponse.complete(
          _page(
            conversation.id,
            <Object?>[_event(1, 'first', conversation.id, body: 'first')],
            nextAfterSeq: 1,
            hasMore: true,
          ),
        );
        await Future.wait(<Future<HeartbeatProactiveSyncResult>>[one, two]);
        expect(api.calls, hasLength(2));
        expect(
          (await chatService.loadMessages(
            conversation.id,
          )).map((m) => m.content),
          <String>['first', 'second'],
        );
      },
    );
  });
}
