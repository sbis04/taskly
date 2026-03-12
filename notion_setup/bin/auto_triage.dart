import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/notion_client.dart';

/// Called by GitHub Action after issue ingestion to auto-triage via Gemini.
/// Classifies issue as Bug or Feature, then routes to the appropriate backlog.
///
/// - Bug (confident) → Maintenance Backlog → outputs issue_type=bug
/// - Feature (confident) → Feature Backlog → outputs issue_type=feature
/// - Not confident → stays in Triage Queue → outputs issue_type=needs_review
///
/// Expects env vars: NOTION_TOKEN, NOTION_TRIAGE_DB_ID, NOTION_DATABASE_ID,
///   NOTION_FEATURE_DB_ID, NOTION_VISION_PAGE_ID, GEMINI_API_KEY,
///   ISSUE_TITLE, ISSUE_BODY, ISSUE_NUMBER, GITHUB_OUTPUT
void main() async {
  final token = Platform.environment['NOTION_TOKEN'];
  final triageDbId = Platform.environment['NOTION_TRIAGE_DB_ID'];
  final bugDbId = Platform.environment['NOTION_DATABASE_ID'];
  final featureDbId = Platform.environment['NOTION_FEATURE_DB_ID'];
  final visionPageId = Platform.environment['NOTION_VISION_PAGE_ID'];
  final geminiKey = Platform.environment['GEMINI_API_KEY'];
  final issueTitle = Platform.environment['ISSUE_TITLE'] ?? '';
  final issueBody = Platform.environment['ISSUE_BODY'] ?? '';
  final issueNumberStr = Platform.environment['ISSUE_NUMBER'] ?? '0';
  final githubOutput = Platform.environment['GITHUB_OUTPUT'] ?? '';

  if (token == null ||
      triageDbId == null ||
      bugDbId == null ||
      featureDbId == null ||
      visionPageId == null ||
      geminiKey == null) {
    stderr.writeln(
        'Required: NOTION_TOKEN, NOTION_TRIAGE_DB_ID, NOTION_DATABASE_ID, '
        'NOTION_FEATURE_DB_ID, NOTION_VISION_PAGE_ID, GEMINI_API_KEY');
    exit(1);
  }

  final issueNumber = int.tryParse(issueNumberStr) ?? 0;
  final client = NotionClient(token: token);
  final httpClient = http.Client();

  // 1. Find the triage page we just created
  print('Finding Triage Queue page for issue #$issueNumber...');
  final pages = await client.queryDatabase(
    triageDbId,
    filter: {
      'property': 'Issue Number',
      'number': {'equals': issueNumber},
    },
  );

  if (pages.isEmpty) {
    stderr.writeln('No Triage Queue page found for issue #$issueNumber');
    exit(1);
  }

  final triagePageId = pages.first['id'] as String;
  final issueUrl = _extractUrl(pages.first, 'GitHub Issue');
  print('Found triage page: $triagePageId');

  // 2. Get vision statement
  print('Reading vision statement...');
  final visionResponse = await httpClient.get(
    Uri.parse(
        'https://api.notion.com/v1/blocks/$visionPageId/children?page_size=100'),
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

  // 3. Call Gemini for triage + classification
  print('Calling Gemini for triage...');
  final prompt = '''You are a senior open-source maintainer triaging a GitHub issue.

PROJECT VISION:
${vision.toString().trim()}

ISSUE TITLE: $issueTitle

ISSUE BODY:
$issueBody

Analyze this issue and respond with ONLY a JSON object (no markdown, no code fences):
{
  "issue_type": "bug" | "feature",
  "type_confidence": 90,
  "priority": "P0-Critical" | "P1-High" | "P2-Medium" | "P3-Low",
  "labels": ["Bug" | "Feature" | "Docs" | "Performance" | "Security" | "Chore"],
  "summary": "1-3 bullet points (max 300 chars total). Keep it concise.",
  "reasoning": "Your detailed analysis of why you classified this as bug/feature and assigned this priority"
}

Classification guidelines:
- "bug": Something is broken, not working as expected, crashes, errors, regressions
- "feature": New functionality, enhancement, improvement, UI change request

type_confidence is 0-100 for how confident you are in the bug/feature classification.
If below 70, the issue will stay in triage for human review.

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
    stderr.writeln(
        'Gemini API error: ${geminiResponse.statusCode} ${geminiResponse.body}');
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

  final issueType = (triage['issue_type'] as String? ?? 'bug').toLowerCase();
  final typeConfidence = (triage['type_confidence'] as num?)?.toInt() ?? 50;
  final priority = triage['priority'] as String? ?? 'P2-Medium';
  final labels = (triage['labels'] as List?)?.cast<String>() ?? ['Bug'];
  final rawSummary = triage['summary'];
  final summary = rawSummary is List
      ? rawSummary.map((e) => '• $e').join('\n')
      : (rawSummary as String? ?? '');
  final rawReasoning = triage['reasoning'];
  final reasoning = rawReasoning is List
      ? rawReasoning.join('\n')
      : (rawReasoning as String? ?? '');

  print('Triage: type=$issueType (confidence=$typeConfidence%), '
      'priority=$priority, labels=$labels');

  // 4. Update triage page with AI results
  await client.updatePage(
    triagePageId,
    properties: {
      'Stage': {
        'select': {
          'name': typeConfidence >= 70 ? 'Routed' : 'Needs Review'
        }
      },
      'Issue Type': {
        'select': {'name': issueType == 'feature' ? 'Feature' : 'Bug'}
      },
      'Priority': {'select': {'name': priority}},
      'Labels': {
        'multi_select': labels.map((l) => {'name': l}).toList(),
      },
      'AI Summary': {
        'rich_text': [
          {
            'text': {
              'content': summary.length > 300
                  ? '${summary.substring(0, 297)}...'
                  : summary
            }
          }
        ]
      },
      'AI Confidence': {'number': typeConfidence},
    },
  );

  // Append triage analysis to triage page
  await httpClient.patch(
    Uri.parse('https://api.notion.com/v1/blocks/$triagePageId/children'),
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

  // 5. Route based on classification confidence
  String outputType;

  if (typeConfidence < 70) {
    // Not confident — keep in Triage Queue for human review
    print('Low confidence ($typeConfidence%). Keeping in Triage Queue.');
    outputType = 'needs_review';
  } else if (issueType == 'bug') {
    // Confident bug → create in Maintenance Backlog
    print('Routing bug to Maintenance Backlog...');
    await _createInBacklog(
      client: client,
      databaseId: bugDbId,
      issueTitle: issueTitle,
      issueBody: issueBody,
      issueUrl: issueUrl,
      issueNumber: issueNumber,
      priority: priority,
      labels: labels,
      summary: summary,
      stage: 'Triaged',
    );
    outputType = 'bug';
  } else {
    // Confident feature → create in Feature Backlog
    print('Routing feature to Feature Backlog...');
    await _createInBacklog(
      client: client,
      databaseId: featureDbId,
      issueTitle: issueTitle,
      issueBody: issueBody,
      issueUrl: issueUrl,
      issueNumber: issueNumber,
      priority: priority,
      labels: labels,
      summary: summary,
      stage: 'New',
    );
    outputType = 'feature';
  }

  // 6. Write output for GitHub Actions
  if (githubOutput.isNotEmpty) {
    File(githubOutput).writeAsStringSync(
      'issue_type=$outputType\n',
      mode: FileMode.append,
    );
    print('Wrote issue_type=$outputType to GITHUB_OUTPUT');
  }

  print('Auto-triage complete! Routed as: $outputType');

  httpClient.close();
  client.dispose();
}

Future<void> _createInBacklog({
  required NotionClient client,
  required String databaseId,
  required String issueTitle,
  required String issueBody,
  required String issueUrl,
  required int issueNumber,
  required String priority,
  required List<String> labels,
  required String summary,
  required String stage,
}) async {
  // Build body chunks
  final bodyChunks = <Map<String, dynamic>>[];
  var remaining = issueBody;
  while (remaining.isNotEmpty) {
    final chunk =
        remaining.length > 2000 ? remaining.substring(0, 2000) : remaining;
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
    remaining = remaining.length > 2000 ? remaining.substring(2000) : '';
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
        'select': {'name': stage}
      },
      'Priority': {'select': {'name': priority}},
      'Labels': {
        'multi_select': labels.map((l) => {'name': l}).toList(),
      },
      'GitHub Issue': {'url': issueUrl.isNotEmpty ? issueUrl : null},
      'Issue Number': {'number': issueNumber},
      'AI Summary': {
        'rich_text': [
          {
            'text': {
              'content': summary.length > 300
                  ? '${summary.substring(0, 297)}...'
                  : summary
            }
          }
        ]
      },
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
}

String _extractUrl(Map<String, dynamic> page, String property) {
  try {
    return page['properties'][property]['url'] as String? ?? '';
  } catch (_) {
    return '';
  }
}
