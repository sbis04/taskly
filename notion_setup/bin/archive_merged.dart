import 'dart:io';

import '../lib/notion_client.dart';

/// Called by GitHub Action to archive a Notion backlog item when its PR is merged.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, PR_URL, PR_TITLE
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final databaseId = Platform.environment['NOTION_DATABASE_ID'];
  final prUrl = Platform.environment['PR_URL'] ?? '';

  if (token == null || databaseId == null) {
    stderr.writeln('Required env vars: NOTION_TOKEN, NOTION_DATABASE_ID');
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
    final titleParts = page['properties']?['Title']?['title'] as List? ?? [];
    final title = titleParts.map((t) => t['plain_text'] ?? '').join();

    print('Archiving: $title ($pageId)');

    await client.updatePage(
      pageId,
      properties: {
        'Stage': {
          'select': {'name': 'Archived'}
        },
      },
      archived: true,
    );

    print('Archived successfully.');
  }

  client.dispose();
}
