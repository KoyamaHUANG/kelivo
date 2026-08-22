import 'model_override_payload_parser.dart';

class CustomRequestMerger {
  static const Set<String> _protectedAssistantHeaders = {
    'x-conversation-id',
    'x-kelivo-conversation-id',
    'x-kelivo-assistant-id',
  };
  // These are client-controlled, capability-gated routing headers. A provider
  // or model custom-header row must never turn them on for ordinary traffic.
  static const Set<String> _providerForbiddenHeaders = {
    'x-kelivo-conversation-id',
    'x-kelivo-assistant-id',
  };

  static Map<String, String> mergeHeaders({
    Map<String, String> base = const <String, String>{},
    Map<String, String>? assistant,
    Map<String, String> providerAutomatic = const <String, String>{},
    Map<String, String> provider = const <String, String>{},
    Map<String, String> model = const <String, String>{},
  }) {
    final protected = <String, String>{};
    final ordinaryAssistant = <String, String>{};
    if (assistant != null) {
      for (final entry in assistant.entries) {
        if (_protectedAssistantHeaders.contains(entry.key.toLowerCase())) {
          protected[entry.key] = entry.value;
        } else {
          ordinaryAssistant[entry.key] = entry.value;
        }
      }
    }

    final merged = <String, String>{};
    for (final layer in <Map<String, String>>[
      base,
      ordinaryAssistant,
      _withoutProviderForbiddenHeaders(providerAutomatic),
      _withoutProviderForbiddenHeaders(provider),
      _withoutProviderForbiddenHeaders(model),
      protected,
    ]) {
      _addHeadersCaseInsensitive(merged, layer);
    }
    return merged;
  }

  static Map<String, dynamic> mergeBody({
    Map<String, dynamic>? assistant,
    Object? providerRows,
    Map<String, dynamic> model = const <String, dynamic>{},
  }) {
    final merged = <String, dynamic>{};
    if (assistant != null) {
      for (final entry in assistant.entries) {
        final value = entry.value;
        merged[entry.key] = value is String
            ? ModelOverridePayloadParser.parseOverrideValue(value)
            : value;
      }
    }
    merged.addAll(ModelOverridePayloadParser.customBodyFromRows(providerRows));
    merged.addAll(model);
    return merged;
  }

  static void _addHeadersCaseInsensitive(
    Map<String, String> target,
    Map<String, String> layer,
  ) {
    for (final entry in layer.entries) {
      final normalized = entry.key.toLowerCase();
      target.removeWhere((key, _) => key.toLowerCase() == normalized);
      target[entry.key] = entry.value;
    }
  }

  static Map<String, String> _withoutProviderForbiddenHeaders(
    Map<String, String> headers,
  ) => <String, String>{
    for (final entry in headers.entries)
      if (!_providerForbiddenHeaders.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
  };
}
