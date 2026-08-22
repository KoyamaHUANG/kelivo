import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../providers/settings_provider.dart';
import '../api/chat_api_helpers.dart';
import '../api/chat_api_service.dart';
import 'heartbeat_proactive_models.dart';

class HeartbeatProactiveHttpResponse {
  const HeartbeatProactiveHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Object? body;
}

abstract interface class HeartbeatProactiveApi {
  Future<HeartbeatProactiveHttpResponse> fetchEvents({
    required ProviderConfig config,
    required String modelId,
    required String conversationId,
    required int afterSeq,
    required int limit,
    String? assistantId,
    Duration timeout = const Duration(milliseconds: 2500),
  });
}

typedef HeartbeatProviderHttpClientFactory =
    http.Client Function(ProviderConfig config, Duration timeout);

/// HTTP implementation deliberately reuses ChatApiService's configured
/// provider client so proxy and transport behavior match normal chat traffic.
class HttpHeartbeatProactiveApi implements HeartbeatProactiveApi {
  HttpHeartbeatProactiveApi({HeartbeatProviderHttpClientFactory? clientFactory})
    : _clientFactory =
          clientFactory ??
          ((config, timeout) => ChatApiService.createProviderHttpClient(
            config,
            timeout: timeout,
          ));

  final HeartbeatProviderHttpClientFactory _clientFactory;

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
    final endpoint = buildHeartbeatProactiveEventsEndpoint(config);
    if (endpoint == null) {
      throw const FormatException('heartbeat_proactive_endpoint_invalid');
    }
    final query = <String, String>{
      'conversation_id': conversationId,
      'after_seq': afterSeq.toString(),
      'limit': limit.toString(),
      if ((assistantId ?? '').trim().isNotEmpty)
        'assistant_id': assistantId!.trim(),
    };
    final request = http.Request(
      'GET',
      endpoint.replace(queryParameters: query),
    );
    final headers = customHeaders(
      config,
      modelId,
      baseHeaders: <String, String>{
        'Authorization': 'Bearer ${apiKeyForRequest(config, modelId)}',
        'Accept': 'application/json',
      },
    );
    // Capability and sync requests never carry conversation headers. Those
    // are added only after capability confirmation to a real chat POST.
    headers.removeWhere(
      (name, _) =>
          name.toLowerCase() == heartbeatConversationHeaderName.toLowerCase() ||
          name.toLowerCase() == heartbeatAssistantHeaderName.toLowerCase(),
    );
    request.headers.addAll(headers);

    final client = _clientFactory(config, timeout);
    try {
      final response = await client.send(request).timeout(timeout);
      final raw = await response.stream.bytesToString().timeout(timeout);
      Object? body;
      if (raw.trim().isNotEmpty) {
        try {
          body = jsonDecode(raw);
        } catch (_) {
          body = null;
        }
      }
      return HeartbeatProactiveHttpResponse(
        statusCode: response.statusCode,
        body: body,
      );
    } finally {
      client.close();
    }
  }
}
