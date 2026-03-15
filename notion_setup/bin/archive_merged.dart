import 'dart:io';

import '../lib/notion_client.dart';

/// Called by GitHub Action when a PR is merged.
/// Searches both Maintenance Backlog and Feature Backlog for the PR URL,
/// moves the matching item to the Archive database.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_FEATURE_DB_ID,
///   NOTION_ARCHIVE_DB_ID, PR_URL
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final bugDbId = Platform.environment['NOTION_DATABASE_ID'];
  final featureDbId = Platform.environment['NOTION_FEATURE_DB_ID'];
  final archiveDbId = Platform.environment['NOTION_ARCHIVE_DB_ID'];
  final prUrl = Platform.environment['PR_URL'] ?? '';

  if (token == null || bugDbId == null || archiveDbId == null) {
    stderr.writeln(
        'Required env vars: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_ARCHIVE_DB_ID');
    exit(1);
  }

  if (prUrl.isEmpty) {
    stderr.writeln('PR_URL is empty, nothing to archive.');
    exit(0);
  }

  final client = NotionClient(token: token);

  print('Searching for Notion page with PR URL: $prUrl');

  // Search both databases
  final databasesToSearch = <MapEntry<String, String>>[
    MapEntry(bugDbId, 'Bug'),
    if (featureDbId != null) MapEntry(featureDbId, 'Feature'),
  ];

  var found = false;

  for (final db in databasesToSearch) {
    final pages = await client.queryDatabase(
      db.key,
      filter: {
        'property': 'PR URL',
        'url': {'equals': prUrl},
      },
    );

    for (final page in pages) {
      found = true;
      final pageId = page['id'] as String;
      final props = page['properties'] as Map<String, dynamic>? ?? {};

      final titleParts = props['Title']?['title'] as List? ?? [];
      final title = titleParts.map((t) => t['plain_text'] ?? '').join();

      final priority =
          props['Priority']?['select']?['name'] as String? ?? 'P2-Medium';
      final issueUrl = props['GitHub Issue']?['url'] as String? ?? '';
      final issueNumber =
          (props['Issue Number']?['number'] as num?)?.toInt() ?? 0;
      final prUrlValue = props['PR URL']?['url'] as String? ?? '';
      final aiSummaryParts =
          props['AI Summary']?['rich_text'] as List? ?? [];
      final aiSummary =
          aiSummaryParts.map((t) => t['plain_text'] ?? '').join();
      final labels = (props['Labels']?['multi_select'] as List? ?? [])
          .map((l) => l['name'] as String)
          .toList();

      print('Archiving ${db.value}: $title ($pageId)');

      // Create entry in Archive database
      final now = DateTime.now().toUtc().toIso8601String().split('T').first;
      await client.createDatabasePage(
        databaseId: archiveDbId,
        properties: {
          'Title': {
            'title': [
              {
                'text': {'content': title}
              }
            ]
          },
          'Type': {
            'select': {'name': db.value}
          },
          'Priority': {'select': {'name': priority}},
          'Labels': {
            'multi_select': labels.map((l) => {'name': l}).toList(),
          },
          'GitHub Issue': {
            'url': issueUrl.isNotEmpty ? issueUrl : null
          },
          'Issue Number': {'number': issueNumber},
          'PR URL': {'url': prUrlValue.isNotEmpty ? prUrlValue : null},
          'AI Summary': {
            'rich_text': [
              {
                'text': {'content': aiSummary}
              }
            ]
          },
          'Resolved Date': {
            'date': {'start': now}
          },
        },
      );

      // Archive the original
      await client.updatePage(pageId, archived: true);
      print('Moved to Archive.');
    }
  }

  if (!found) {
    print('No matching page found for PR URL: $prUrl');
    print('This PR may not have been created by Ghost Maintainer.');
  }

  client.dispose();
}
