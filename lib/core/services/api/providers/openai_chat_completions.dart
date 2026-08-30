import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../providers/settings_provider.dart';
import '../../archive_identity/kelivo_archive_identity.dart';
import '../chat_api_helpers.dart';
import '../stream/stream_chunk.dart';

import 'openai/openai_provider.dart';

Stream<StreamChunk> sendOpenAIChatCompletionsStream(
  http.Client client,
  ProviderConfig config,
  String modelId,
  List<Map<String, dynamic>> messages, {
  List<String>? userImagePaths,
  int? thinkingBudget,
  double? temperature,
  double? topP,
  int? maxTokens,
  List<Map<String, dynamic>>? tools,
  ToolCallHandler? onToolCall,
  Map<String, String>? extraHeaders,
  Map<String, dynamic>? extraBody,
  KelivoArchiveIdentity? archiveIdentity,
  bool stream = true,
  bool builtInSearchOnly = false,
  bool skipImageParsing = false,
}) {
  final cfg = config.copyWith(useResponseApi: false);
  return sendOpenAIStream(
    client,
    cfg,
    modelId,
    messages,
    userImagePaths: userImagePaths,
    thinkingBudget: thinkingBudget,
    temperature: temperature,
    topP: topP,
    maxTokens: maxTokens,
    tools: tools,
    onToolCall: onToolCall,
    extraHeaders: extraHeaders,
    extraBody: extraBody,
    archiveIdentity: archiveIdentity,
    stream: stream,
    builtInSearchOnly: builtInSearchOnly,
    skipImageParsing: skipImageParsing,
  );
}
