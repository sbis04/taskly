import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/notion_client.dart';

/// Polls the Feature Backlog for items with Stage = "Implement".
/// For each one found, triggers the implement_feature workflow via GitHub API,
/// then updates the Stage to "Investigating" so it won't be picked up again.
///
/// Expects env vars: NOTION_TOKEN, NOTION_FEATURE_DB_ID,
///   GITHUB_TOKEN, TARGET_REPO
void main() async {
  final token = Platform.environment['NOTION_TOKEN']!;
  final featureDbId = Platform.environment['NOTION_FEATURE_DB_ID']!;
  final githubToken = Platform.environment['GITHUB_TOKEN']!;
  final targetRepo = Platform.environment['TARGET_REPO']!;

  final client = NotionClient(token: token);
  final httpClient = http.Client();

  // Query for features with Stage = "Implement"
  print('Polling Feature Backlog for Stage = Implement...');
  final pages = await client.queryDatabase(
    featureDbId,
    filter: {
      'property': 'Stage',
      'select': {'equals': 'Implement'},
    },
  );

  if (pages.isEmpty) {
    print('No features to implement. Done.');
    httpClient.close();
    client.dispose();
    return;
  }

  print('Found ${pages.length} feature(s) to implement.');

  for (final page in pages) {
    final pageId = page['id'] as String;
    final props = page['properties'] as Map<String, dynamic>;
    final issueNumber =
        (props['Issue Number']?['number'] as num?)?.toInt() ?? 0;
    final titleParts = props['Title']?['title'] as List? ?? [];
    final title = titleParts.map((t) => t['plain_text'] ?? '').join();

    if (issueNumber == 0) {
      print('Skipping "$title" — no issue number.');
      continue;
    }

    print('Triggering implementation for #$issueNumber: $title');

    // Update Stage to "Investigating" immediately so we don't pick it up again
    await client.updatePage(pageId, properties: {
      'Stage': {'select': {'name': 'Investigating'}},
    });

    // Trigger the implement_feature workflow via GitHub API
    final response = await httpClient.post(
      Uri.parse(
          'https://api.github.com/repos/$targetRepo/actions/workflows/implement_feature.yml/dispatches'),
      headers: {
        'Authorization': 'token $githubToken',
        'Accept': 'application/vnd.github.v3+json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'ref': 'main',
        'inputs': {
          'issue_number': '$issueNumber',
        },
      }),
    );

    if (response.statusCode == 204) {
      print('  Workflow triggered for #$issueNumber');
    } else {
      stderr.writeln(
          '  Failed to trigger workflow: ${response.statusCode} ${response.body}');
      // Revert stage so it can be retried
      await client.updatePage(pageId, properties: {
        'Stage': {'select': {'name': 'Implement'}},
      });
    }
  }

  httpClient.close();
  client.dispose();
  print('Done.');
}
