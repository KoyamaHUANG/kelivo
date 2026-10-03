import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/archive_identity/kelivo_archive_identity.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_api.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_models.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_store.dart';
import 'package:Kelivo/core/services/proactive_sync/heartbeat_proactive_sync_service.dart';
import 'package:Kelivo/features/home/controllers/generation_controller.dart';
import 'package:Kelivo/features/home/controllers/stream_controller.dart'
    as stream;
import 'package:Kelivo/features/home/services/message_builder_service.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';
import 'support/business_test_harness.dart';

class _RealHttp extends HttpOverrides {}

class _Context extends Fake implements BuildContext {}

class _Generation extends Fake implements GenerationController {}

class _Stream extends Fake implements stream.StreamController {}

class _Api extends Fake implements HeartbeatProactiveApi {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'identity mapping cannot select synthetic users or disappear after trimming',
    () {
      final user = ChatMessage(
        id: 'fixture-real-user',
        role: 'user',
        conversationId: 'fixture-conversation',
        content: 'fixture',
      );
      final identity = KelivoArchiveIdentity.forUserSend(
        userMessage: user,
        conversationId: user.conversationId,
        assistantId: 'fixture-assistant',
      );
      final api = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'synthetic fixture'},
        {
          'role': 'user',
          'content': 'fixture',
          MessageBuilderService.internalRevisionIdKey: user.id,
        },
        {'role': 'user', 'content': 'another synthetic fixture'},
      ];
      expect(
        mapArchiveIdentityToApiMessages(identity, api)!.userMessageIndex,
        1,
      );
      api.removeAt(1);
      expect(
        () => mapArchiveIdentityToApiMessages(identity, api),
        throwsStateError,
      );
      expect(mapArchiveIdentityToApiMessages(null, api), isNull);
    },
  );

  test(
    'all actual chat entry points pass the shared identity to both request layers',
    () {
      final actions = File(
        'lib/features/home/controllers/chat_actions.dart',
      ).readAsStringSync();
      final regenerationStart = actions.indexOf(
        '  Future<ChatActionResult> regenerateAtMessage(',
      );
      final claimedStart = actions.indexOf(
        '  Future<ChatActionResult> _regenerateAtMessageClaimed(',
      );
      final recoveryStart = actions.indexOf(
        '  Future<ChatActionResult> continueAssistantMessageAfterToolAnswer(',
      );
      final sections = [
        actions.substring(0, regenerationStart),
        actions.substring(claimedStart, recoveryStart),
        actions.substring(recoveryStart),
      ];
      for (final section in sections) {
        expect(section, contains('prepareHeartbeatGenerationIdentity('));
        expect(section, contains('archiveIdentity: requestIdentity.identity'));
        expect(section, contains('heartbeatHeaders: requestIdentity.headers'));
      }
      expect(
        sections[1].indexOf('prepareHeartbeatGenerationIdentity('),
        lessThan(
          sections[1].indexOf('shouldPhysicallyRemoveRegenerationTail('),
        ),
      );
      expect(
        sections[2].indexOf('prepareHeartbeatGenerationIdentity('),
        lessThan(sections[2].indexOf('await chatService.updateMessage(')),
      );
      final controller = File(
        'lib/features/home/controllers/home_page_controller.dart',
      ).readAsStringSync();
      expect(
        controller,
        contains('regenerateAtMessage(newMsg, allowNewArchiveRequest: true)'),
      );
      expect(
        File(
          'lib/features/home/controllers/home_view_model.dart',
        ).readAsStringSync(),
        contains('allowNewArchiveRequest: allowNewArchiveRequest'),
      );
    },
  );

  test(
    'selected edited revision, regeneration and manual recovery reach the final HTTP request with one scope',
    () async {
      final requests = <Map<String, dynamic>>[];
      final requestHeaders = <Map<String, String?>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        requestHeaders.add({
          for (final key in [
            'x-kelivo-assistant-id',
            'x-kelivo-conversation-id',
            'x-kelivo-archive-protocol',
            'x-kelivo-request-id',
            'x-kelivo-user-message-id',
          ])
            key: request.headers.value(key),
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'fixture-ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
        await request.response.close();
      });

      final harness = await createBusinessTestHarness();
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      addTearDown(settings.dispose);
      final config = ProviderConfig(
        id: 'fixture-provider',
        enabled: true,
        name: 'fixture',
        apiKey: 'fixture-key',
        baseUrl: 'http://${server.address.address}:${server.port}/v1',
        providerType: ProviderKind.openai,
      );
      await settings.setProviderConfig(config.id, config);
      final scope = heartbeatProviderIdentity(
        config.id,
        normalizeHeartbeatBaseUrl(config.baseUrl),
      );
      final store = HeartbeatProactiveStore(preferences: harness.preferences);
      await store.setPositiveCapability(scope);
      await store.setArchiveIdentityProtocolVersion(scope, 1);
      final chat = ChatService();
      final context = _Context();
      final service = MessageGenerationService(
        chatService: chat,
        messageBuilderService: MessageBuilderService(
          chatService: chat,
          contextProvider: context,
        ),
        generationController: _Generation(),
        streamController: _Stream(),
        contextProvider: context,
        heartbeatProactiveSyncService: HeartbeatProactiveSyncService(
          chatService: chat,
          store: store,
          api: _Api(),
        ),
      );
      final conversation = Conversation(
        id: 'fixture-conversation',
        title: 'fixture',
        assistantId: 'fixture-assistant',
      );
      final original = ChatMessage(
        id: 'fixture-user-v0',
        role: 'user',
        conversationId: conversation.id,
        content: 'fixture-original',
        groupId: 'fixture-group',
        version: 0,
      );
      final edited = original.copyWith(
        id: 'fixture-user-v1',
        content: 'fixture-edited',
        version: 1,
      );
      final assistant = ChatMessage(
        id: 'fixture-assistant-message',
        role: 'assistant',
        conversationId: conversation.id,
        content: 'fixture',
      );
      final roots = <String>[];
      for (final operation in [
        'send',
        'regenerate',
        'edited resend',
        'manual recovery',
      ]) {
        final isEdited =
            operation == 'edited resend' || operation == 'manual recovery';
        final selection = {'fixture-group': isEdited ? 1 : 0};
        final user = isEdited ? edited : original;
        final identity = await service.prepareHeartbeatGenerationIdentity(
          conversation: conversation,
          settings: settings,
          providerId: config.id,
          modelId: 'fixture-model',
          messages: [original, edited, assistant],
          versionSelections: selection,
          allowNewRequest: operation == 'send' || operation == 'edited resend',
        );
        expect(identity.identity!.userMessageId, user.id, reason: operation);
        final mapped = identity.identity!.withUserMessageIndex(0);
        roots.add(mapped.requestId);
        await HttpOverrides.runWithHttpOverrides(
          () => ChatApiService.sendMessageStream(
            config: config,
            modelId: 'fixture-model',
            messages: [
              {'role': 'user', 'content': user.content},
            ],
            stream: false,
            extraHeaders: buildConversationRequestHeaders(
              conversationId: conversation.id,
              heartbeatHeaders: identity.headers,
            ),
            archiveIdentity: mapped,
          ).toList(),
          _RealHttp(),
        );
      }
      expect(requests, hasLength(4));
      expect(roots[0], roots[1]);
      expect(roots[2], roots[3]);
      expect(roots[0], isNot(roots[2]));
      for (var i = 0; i < requests.length; i++) {
        final envelope = requests[i]['_kelivo_archive'] as Map;
        final headers = requestHeaders[i];
        expect(
          headers['x-kelivo-conversation-id'],
          envelope['conversation_id'],
        );
        expect(headers['x-kelivo-assistant-id'], envelope['assistant_id']);
        expect(headers['x-kelivo-request-id'], envelope['request_id']);
        expect(
          headers['x-kelivo-user-message-id'],
          envelope['user_message_id'],
        );
        expect(headers['x-kelivo-archive-protocol'], '1');
        expect(envelope['user_message_id'], i < 2 ? original.id : edited.id);
      }
      // A new preference facade reads the SQLite snapshot, not the old cache.
      final reloadedPreferences = BusinessPreferences(harness.repository);
      await reloadedPreferences.load();
      final recordedKey = harness.preferences.getKeys().firstWhere(
        (key) => key.startsWith('heartbeat_archive_request_v1:'),
      );
      expect(
        reloadedPreferences.getString(recordedKey),
        harness.preferences.getString(recordedKey),
      );
    },
  );
}
