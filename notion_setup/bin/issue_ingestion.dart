import 'dart:io';

import '../lib/notion_client.dart';

/// Called by GitHub Action to create a Notion backlog entry from a new issue.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID,
///   ISSUE_TITLE, ISSUE_BODY, ISSUE_URL, ISSUE_NUMBER
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final databaseId = Platform.environment['NOTION_DATABASE_ID'];
  final issueTitle = Platform.environment['ISSUE_TITLE'] ?? 'Untitled Issue';
  final issueBody = Platform.environment['ISSUE_BODY'] ?? '';
  final issueUrl = Platform.environment['ISSUE_URL'] ?? '';
  final issueNumberStr = Platform.environment['ISSUE_NUMBER'] ?? '0';

  if (token == null || databaseId == null) {
    stderr.writeln('Required env vars: NOTION_TOKEN, NOTION_DATABASE_ID');
    exit(1);
  }

  final issueNumber = int.tryParse(issueNumberStr) ?? 0;
  final client = NotionClient(token: token);

  print('Creating Notion backlog entry for issue #$issueNumber: $issueTitle');

  // Truncate body for Notion block (max 2000 chars per block)
  final bodyChunks = <Map<String, dynamic>>[];
  var remaining = issueBody;
  while (remaining.isNotEmpty) {
    final chunk = remaining.length > 2000
        ? remaining.substring(0, 2000)
        : remaining;
    bodyChunks.add({
      'object': 'block',
      'type': 'paragraph',
      'paragraph': {
        'rich_text': [
          {
            'type': 'text',
            'text': {'content': chunk}
          }
        ]
      },
    });
    remaining =
        remaining.length > 2000 ? remaining.substring(2000) : '';
  }

  if (bodyChunks.isEmpty) {
    bodyChunks.add({
      'object': 'block',
      'type': 'paragraph',
      'paragraph': {
        'rich_text': [
          {
            'type': 'text',
            'text': {'content': '(No issue body provided)'}
          }
        ]
      },
    });
  }

  await client.createDatabasePage(
    databaseId: databaseId,
    properties: {
      'Title': {
        'title': [
          {
            'text': {'content': issueTitle}
          }
        ]
      },
      'Stage': {
        'select': {'name': 'New'}
      },
      'GitHub Issue': {'url': issueUrl.isNotEmpty ? issueUrl : null},
      'Issue Number': {'number': issueNumber},
    },
    children: [
      {
        'object': 'block',
        'type': 'heading_2',
        'heading_2': {
          'rich_text': [
            {
              'type': 'text',
              'text': {'content': 'Original Issue'}
            }
          ]
        },
      },
      ...bodyChunks,
      {
        'object': 'block',
        'type': 'divider',
        'divider': {},
      },
    ],
  );

  print('Backlog entry created successfully.');
  client.dispose();
}
