import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Lightweight Notion API client for setup scripts.
class NotionClient {
  final String token;
  final _client = http.Client();
  static const _baseUrl = 'https://api.notion.com/v1';
  static const _notionVersion = '2022-06-28';

  NotionClient({required this.token});

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Notion-Version': _notionVersion,
      };

  Future<Map<String, dynamic>> createDatabase({
    required String parentPageId,
    required String title,
    required Map<String, dynamic> properties,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/databases'),
      headers: _headers,
      body: jsonEncode({
        'parent': {'type': 'page_id', 'page_id': parentPageId},
        'title': [
          {
            'type': 'text',
            'text': {'content': title}
          }
        ],
        'properties': properties,
      }),
    );
    return _handle(response);
  }

  Future<Map<String, dynamic>> createPage({
    required String parentPageId,
    required String title,
    required List<Map<String, dynamic>> children,
  }) async {
    final response = await _client.post(
      Uri.parse('$_baseUrl/pages'),
      headers: _headers,
      body: jsonEncode({
        'parent': {'page_id': parentPageId},
        'properties': {
          'title': {
            'title': [
              {
                'text': {'content': title}
              }
            ]
          }
        },
        'children': children,
      }),
    );
    return _handle(response);
  }

  Future<Map<String, dynamic>> createDatabasePage({
    required String databaseId,
    required Map<String, dynamic> properties,
    List<Map<String, dynamic>>? children,
  }) async {
    final body = <String, dynamic>{
      'parent': {'database_id': databaseId},
      'properties': properties,
    };
    if (children != null) body['children'] = children;

    final response = await _client.post(
      Uri.parse('$_baseUrl/pages'),
      headers: _headers,
      body: jsonEncode(body),
    );
    return _handle(response);
  }

  Future<List<Map<String, dynamic>>> queryDatabase(
    String databaseId, {
    Map<String, dynamic>? filter,
  }) async {
    final body = <String, dynamic>{};
    if (filter != null) body['filter'] = filter;

    final response = await _client.post(
      Uri.parse('$_baseUrl/databases/$databaseId/query'),
      headers: _headers,
      body: jsonEncode(body),
    );
    final data = _handle(response);
    return (data['results'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> updatePage(
    String pageId, {
    Map<String, dynamic>? properties,
    bool? archived,
  }) async {
    final body = <String, dynamic>{};
    if (properties != null) body['properties'] = properties;
    if (archived != null) body['archived'] = archived;

    final response = await _client.patch(
      Uri.parse('$_baseUrl/pages/$pageId'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _handle(response);
  }

  Map<String, dynamic> _handle(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    stderr.writeln('Notion API error ${response.statusCode}: ${response.body}');
    exit(1);
  }

  void dispose() => _client.close();
}
