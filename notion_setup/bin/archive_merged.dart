import 'dart:io';

import '../lib/notion_client.dart';

/// Called by GitHub Action when a PR is merged.
/// Moves the matching Maintenance Backlog item to the Archive database.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_ARCHIVE_DB_ID,
///   PR_URL, PR_TITLE
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final databaseId = Platform.environment['NOTION_DATABASE_ID'];
  final archiveDbId = Platform.environment['NOTION_ARCHIVE_DB_ID'];
  final prUrl = Platform.environment['PR_URL'] ?? '';

  if (token == null || databaseId == null || archiveDbId == null) {
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

  // Query for pages matching this PR URL
  final pages = await client.queryDatabase(
    databaseId,
    filter: {
      'property': 'PR URL',
      'url': {'equals': prUrl},
    },
  );

  if (pages.isEmpty) {
    print('No matching backlog item found for PR URL: $prUrl');
    print('This PR may not have been created by Ghost Maintainer.');
    exit(0);
  }

  for (final page in pages) {
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

    print('Archiving: $title ($pageId)');

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
          'select': {'name': 'Bug'}
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

    // Archive the original from Maintenance Backlog
    await client.updatePage(pageId, archived: true);

    print('Moved to Archive and removed from Maintenance Backlog.');
  }

  client.dispose();
}
