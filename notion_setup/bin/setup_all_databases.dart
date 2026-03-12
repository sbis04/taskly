import 'dart:io';

import '../lib/notion_client.dart';

/// Creates the Triage Queue and Feature Backlog databases in Notion.
///
/// The Maintenance Backlog should already exist. This script creates the
/// two additional databases needed for the routing flow.
///
/// Usage:
///   NOTION_TOKEN=ntn_... PARENT_PAGE_ID=... dart run bin/setup_all_databases.dart
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final parentPageId = Platform.environment['PARENT_PAGE_ID'];

  if (token == null || parentPageId == null) {
    stderr.writeln('Required env vars: NOTION_TOKEN, PARENT_PAGE_ID');
    exit(1);
  }

  final client = NotionClient(token: token);

  // 1. Create Triage Queue
  print('Creating Triage Queue database...');
  final triageDb = await client.createDatabase(
    parentPageId: parentPageId,
    title: 'Triage Queue',
    properties: {
      'Title': {'title': {}},
      'Stage': {
        'select': {
          'options': [
            {'name': 'New', 'color': 'gray'},
            {'name': 'Triaged', 'color': 'blue'},
            {'name': 'Needs Review', 'color': 'orange'},
            {'name': 'Routed', 'color': 'green'},
          ]
        }
      },
      'Issue Type': {
        'select': {
          'options': [
            {'name': 'Bug', 'color': 'red'},
            {'name': 'Feature', 'color': 'blue'},
            {'name': 'Unknown', 'color': 'gray'},
          ]
        }
      },
      'Priority': {
        'select': {
          'options': [
            {'name': 'P0-Critical', 'color': 'red'},
            {'name': 'P1-High', 'color': 'orange'},
            {'name': 'P2-Medium', 'color': 'yellow'},
            {'name': 'P3-Low', 'color': 'gray'},
          ]
        }
      },
      'Labels': {
        'multi_select': {
          'options': [
            {'name': 'Bug', 'color': 'red'},
            {'name': 'Feature', 'color': 'blue'},
            {'name': 'Docs', 'color': 'green'},
            {'name': 'Performance', 'color': 'yellow'},
            {'name': 'Security', 'color': 'pink'},
            {'name': 'Chore', 'color': 'gray'},
          ]
        }
      },
      'GitHub Issue': {'url': {}},
      'Issue Number': {'number': {'format': 'number'}},
      'AI Summary': {'rich_text': {}},
      'AI Confidence': {'number': {'format': 'number'}},
    },
  );

  final triageDbId = triageDb['id'];
  print('Triage Queue created! ID: $triageDbId');

  // 2. Create Feature Backlog
  print('\nCreating Feature Backlog database...');
  final featureDb = await client.createDatabase(
    parentPageId: parentPageId,
    title: 'Feature Backlog',
    properties: {
      'Title': {'title': {}},
      'Stage': {
        'select': {
          'options': [
            {'name': 'New', 'color': 'gray'},
            {'name': 'Planned', 'color': 'blue'},
            {'name': 'In Progress', 'color': 'yellow'},
            {'name': 'Done', 'color': 'green'},
            {'name': 'Archived', 'color': 'default'},
          ]
        }
      },
      'Priority': {
        'select': {
          'options': [
            {'name': 'P0-Critical', 'color': 'red'},
            {'name': 'P1-High', 'color': 'orange'},
            {'name': 'P2-Medium', 'color': 'yellow'},
            {'name': 'P3-Low', 'color': 'gray'},
          ]
        }
      },
      'Labels': {
        'multi_select': {
          'options': [
            {'name': 'Feature', 'color': 'blue'},
            {'name': 'Enhancement', 'color': 'purple'},
            {'name': 'Docs', 'color': 'green'},
            {'name': 'Performance', 'color': 'yellow'},
          ]
        }
      },
      'GitHub Issue': {'url': {}},
      'Issue Number': {'number': {'format': 'number'}},
      'AI Summary': {'rich_text': {}},
    },
  );

  final featureDbId = featureDb['id'];
  print('Feature Backlog created! ID: $featureDbId');

  print('\n--- Add these to your .env file ---');
  print('NOTION_TRIAGE_DB_ID=$triageDbId');
  print('NOTION_FEATURE_DB_ID=$featureDbId');

  client.dispose();
}
