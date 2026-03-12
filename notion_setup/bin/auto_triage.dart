import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/notion_client.dart';

/// Called by GitHub Action after issue ingestion to auto-triage via Gemini.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_VISION_PAGE_ID,
///   GEMINI_API_KEY, ISSUE_TITLE, ISSUE_BODY, ISSUE_NUMBER
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final databaseId = Platform.environment['NOTION_DATABASE_ID'];
  final visionPageId = Platform.environment['NOTION_VISION_PAGE_ID'];
  final geminiKey = Platform.environment['GEMINI_API_KEY'];
  final issueTitle = Platform.environment['ISSUE_TITLE'] ?? '';
  final issueBody = Platform.environment['ISSUE_BODY'] ?? '';
  final issueNumberStr = Platform.environment['ISSUE_NUMBER'] ?? '0';

  if (token == null || databaseId == null || visionPageId == null || geminiKey == null) {
    stderr.writeln(
        'Required: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_VISION_PAGE_ID, GEMINI_API_KEY');
    exit(1);
  }

  final issueNumber = int.tryParse(issueNumberStr) ?? 0;
  final client = NotionClient(token: token);
  final httpClient = http.Client();

  // 1. Find the page we just created by issue number
  print('Finding Notion page for issue #$issueNumber...');
  final pages = await client.queryDatabase(
    databaseId,
    filter: {
      'property': 'Issue Number',
      'number': {'equals': issueNumber},
    },
  );

  if (pages.isEmpty) {
    stderr.writeln('No Notion page found for issue #$issueNumber');
    exit(1);
  }

  final pageId = pages.first['id'] as String;
  print('Found page: $pageId');

  // 2. Get vision statement
  print('Reading vision statement...');
  final visionResponse = await httpClient.get(
    Uri.parse('https://api.notion.com/v1/blocks/$visionPageId/children?page_size=100'),
    headers: {
      'Authorization': 'Bearer $token',
      'Notion-Version': '2022-06-28',
    },
  );
  final visionData = jsonDecode(visionResponse.body) as Map<String, dynamic>;
  final visionBlocks = visionData['results'] as List;
  final vision = StringBuffer();
  for (final block in visionBlocks) {
    final type = block['type'] as String;
    final richTexts = block[type]?['rich_text'] as List? ?? [];
    for (final rt in richTexts) {
      vision.write(rt['plain_text'] ?? '');
    }
    vision.writeln();
  }

  // 3. Call Gemini for triage
  print('Calling Gemini for triage...');
  final prompt = '''You are a senior open-source maintainer triaging a GitHub issue.

PROJECT VISION:
${vision.toString().trim()}

ISSUE TITLE: $issueTitle

ISSUE BODY:
$issueBody

Analyze this issue and respond with ONLY a JSON object (no markdown, no code fences):
{
  "priority": "P0-Critical" | "P1-High" | "P2-Medium" | "P3-Low",
  "labels": ["Bug" | "Feature" | "Docs" | "Performance" | "Security" | "Chore"],
  "summary": "One paragraph summary of the issue and recommended action",
  "reasoning": "Your detailed analysis of why you assigned this priority and these labels"
}

Priority guidelines:
- P0-Critical: Security vulnerabilities, data loss, complete feature breakage
- P1-High: Major bugs affecting many users, blocked workflows
- P2-Medium: Minor bugs, UX issues, small feature requests
- P3-Low: Cosmetic issues, nice-to-haves, documentation gaps''';

  final geminiResponse = await httpClient.post(
    Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$geminiKey'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.2,
        'maxOutputTokens': 16384,
        'responseMimeType': 'application/json',
      },
    }),
  );

  if (geminiResponse.statusCode != 200) {
    stderr.writeln('Gemini API error: ${geminiResponse.statusCode} ${geminiResponse.body}');
    exit(1);
  }

  final geminiData = jsonDecode(geminiResponse.body) as Map<String, dynamic>;
  final candidates = geminiData['candidates'] as List;
  final responseText =
      candidates.first['content']['parts'].first['text'] as String;

  // Parse JSON response
  Map<String, dynamic> triage;
  try {
    triage = jsonDecode(responseText) as Map<String, dynamic>;
  } catch (_) {
    final start = responseText.indexOf('{');
    final end = responseText.lastIndexOf('}');
    if (start != -1 && end > start) {
      triage = jsonDecode(responseText.substring(start, end + 1))
          as Map<String, dynamic>;
    } else {
      stderr.writeln('Failed to parse Gemini response: $responseText');
      exit(1);
    }
  }

  final priority = triage['priority'] as String? ?? 'P2-Medium';
  final labels = (triage['labels'] as List?)?.cast<String>() ?? ['Bug'];
  final summary = triage['summary'] as String? ?? '';
  final reasoning = triage['reasoning'] as String? ?? '';

  print('Triage result: $priority, labels: $labels');

  // 4. Update Notion page with triage results
  print('Updating Notion page...');
  await client.updatePage(
    pageId,
    properties: {
      'Stage': {'select': {'name': 'Triaged'}},
      'Priority': {'select': {'name': priority}},
      'Labels': {
        'multi_select': labels.map((l) => {'name': l}).toList(),
      },
      'AI Summary': {
        'rich_text': [
          {
            'text': {
              'content': summary.length > 2000
                  ? '${summary.substring(0, 1997)}...'
                  : summary
            }
          }
        ]
      },
    },
  );

  // 5. Append triage analysis to page
  final appendResponse = await httpClient.patch(
    Uri.parse('https://api.notion.com/v1/blocks/$pageId/children'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Notion-Version': '2022-06-28',
    },
    body: jsonEncode({
      'children': [
        {
          'object': 'block',
          'type': 'heading_2',
          'heading_2': {
            'rich_text': [
              {'type': 'text', 'text': {'content': 'Triage Analysis'}}
            ]
          },
        },
        {
          'object': 'block',
          'type': 'paragraph',
          'paragraph': {
            'rich_text': [
              {
                'type': 'text',
                'text': {
                  'content': reasoning.length > 2000
                      ? '${reasoning.substring(0, 1997)}...'
                      : reasoning
                }
              }
            ]
          },
        },
        {
          'object': 'block',
          'type': 'divider',
          'divider': {},
        },
      ],
    }),
  );

  if (appendResponse.statusCode >= 200 && appendResponse.statusCode < 300) {
    print('Auto-triage complete! Stage set to Triaged.');
  } else {
    stderr.writeln('Failed to append triage: ${appendResponse.body}');
  }

  httpClient.close();
  client.dispose();
}
