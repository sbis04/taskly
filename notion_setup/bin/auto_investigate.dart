import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/notion_client.dart';

/// Called by GitHub Action after triage routes a BUG to Maintenance Backlog.
/// Reads source files from the local checkout, sends to Gemini, writes results to Notion.
/// Only runs for bugs — features skip investigation and go straight to the backlog.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, NOTION_VISION_PAGE_ID,
///   GEMINI_API_KEY, ISSUE_TITLE, ISSUE_BODY, ISSUE_NUMBER, GITHUB_WORKSPACE
void main() async {
  final token = Platform.environment['NOTION_TOKEN']!;
  final databaseId = Platform.environment['NOTION_DATABASE_ID']!;
  final visionPageId = Platform.environment['NOTION_VISION_PAGE_ID']!;
  final geminiKey = Platform.environment['GEMINI_API_KEY']!;
  final issueTitle = Platform.environment['ISSUE_TITLE'] ?? '';
  final issueBody = Platform.environment['ISSUE_BODY'] ?? '';
  final issueNumberStr = Platform.environment['ISSUE_NUMBER'] ?? '0';
  final workspace = Platform.environment['GITHUB_WORKSPACE'] ?? '.';

  final issueNumber = int.tryParse(issueNumberStr) ?? 0;
  final client = NotionClient(token: token);
  final httpClient = http.Client();

  // 1. Find the Notion page
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

  // 2. Update stage to Investigating
  await client.updatePage(pageId, properties: {
    'Stage': {'select': {'name': 'Investigating'}},
  });

  // 3. Read source files from the checked-out repo
  print('Reading source files from $workspace...');
  final sourceFiles = _collectSourceFiles(Directory(workspace));
  print('Found ${sourceFiles.length} source files');

  // Build file contents map (limit to keep within token budget)
  final fileContents = <String, String>{};
  var totalSize = 0;
  const maxTotalSize = 100000; // ~100KB of source code

  for (final file in sourceFiles) {
    final relativePath =
        file.path.substring(workspace.length + 1);
    final content = file.readAsStringSync();
    if (totalSize + content.length > maxTotalSize) continue;
    fileContents[relativePath] = content;
    totalSize += content.length;
  }

  print('Sending ${fileContents.length} files to Gemini (${totalSize}B)...');

  // 4. Get vision statement
  final vision = await _getVisionStatement(httpClient, token, visionPageId);

  // 5. Call Gemini to investigate
  final filesSection = fileContents.entries
      .map((e) => '--- ${e.key} ---\n${e.value}')
      .join('\n\n');

  final prompt = '''You are a senior developer investigating a GitHub issue and proposing a fix.

PROJECT VISION:
$vision

ISSUE TITLE: $issueTitle

ISSUE BODY:
$issueBody

FULL SOURCE CODE:
$filesSection

Analyze the issue, identify the root cause, and propose a concrete fix.
Respond with ONLY a JSON object (no markdown, no code fences):
{
  "analysis": "Detailed root cause analysis",
  "affected_files": ["list of file paths that need changes"],
  "proposed_changes": [
    {
      "file": "path/to/file (relative to repo root)",
      "new_content": "THE COMPLETE NEW FILE CONTENT (not a diff, the full file)"
    }
  ],
  "explanation": "Human-readable explanation of the fix",
  "confidence": 85
}

IMPORTANT: For each changed file, provide the COMPLETE new file content, not just a diff.
Only include files that actually need changes. Be precise and make minimal changes.
Confidence is 0-100 representing how confident you are the fix is correct.''';

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
        'maxOutputTokens': 65536,
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
  final responseText = geminiData['candidates'][0]['content']['parts'][0]['text'] as String;

  Map<String, dynamic> result;
  try {
    result = jsonDecode(responseText) as Map<String, dynamic>;
  } catch (_) {
    final start = responseText.indexOf('{');
    final end = responseText.lastIndexOf('}');
    if (start != -1 && end > start) {
      result = jsonDecode(responseText.substring(start, end + 1))
          as Map<String, dynamic>;
    } else {
      stderr.writeln('Failed to parse Gemini response');
      exit(1);
    }
  }

  final analysis = result['analysis'] as String? ?? '';
  final explanation = result['explanation'] as String? ?? '';
  final confidence = (result['confidence'] as num?)?.toInt() ?? 0;
  final changes = (result['proposed_changes'] as List?) ?? [];

  print('Investigation complete. Confidence: $confidence%');
  print('Affected files: ${changes.length}');

  // 6. Write proposed changes to a JSON file for the deploy step
  final changesFile = File('$workspace/.ghost_changes.json');
  changesFile.writeAsStringSync(jsonEncode({
    'analysis': analysis,
    'explanation': explanation,
    'confidence': confidence,
    'changes': changes,
  }));
  print('Changes written to .ghost_changes.json');

  // 7. Update Notion with investigation results
  await client.updatePage(pageId, properties: {
    'Stage': {'select': {'name': 'Review'}},
    'AI Summary': {
      'rich_text': [
        {
          'text': {
            'content': _truncate(explanation, 2000),
          }
        }
      ]
    },
    'AI Confidence': {'number': confidence},
  });

  // Build a summary diff for Notion
  final diffSummary = StringBuffer();
  for (final change in changes) {
    diffSummary.writeln('File: ${change['file']}');
  }

  await _appendBlocks(httpClient, token, pageId, [
    _heading2('Investigation Report'),
    _paragraph(_truncate(analysis, 2000)),
    _heading2('Proposed Fix'),
    _paragraph(_truncate('Confidence: $confidence%\n\n$explanation', 2000)),
    _codeBlock(_truncate(diffSummary.toString(), 2000)),
    _divider(),
  ]);

  print('Notion page updated with investigation. Stage set to Review.');

  httpClient.close();
  client.dispose();
}

List<File> _collectSourceFiles(Directory dir) {
  final files = <File>[];
  const extensions = ['.dart', '.py', '.js', '.ts', '.java', '.kt', '.go',
    '.rs', '.rb', '.swift', '.c', '.cpp', '.h', '.yaml', '.yml', '.json'];
  const ignoreDirs = ['.git', '.dart_tool', 'build', 'node_modules',
    '.github', '.idea', 'notion_setup'];

  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path;

    // Skip ignored directories
    if (ignoreDirs.any((d) => path.contains('/$d/'))) continue;

    // Only include source files
    if (extensions.any(path.endsWith)) {
      files.add(entity);
    }
  }

  // Sort by size (smaller first) to maximize coverage
  files.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
  return files;
}

Future<String> _getVisionStatement(
    http.Client client, String token, String pageId) async {
  final response = await client.get(
    Uri.parse('https://api.notion.com/v1/blocks/$pageId/children?page_size=100'),
    headers: {
      'Authorization': 'Bearer $token',
      'Notion-Version': '2022-06-28',
    },
  );
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final blocks = data['results'] as List;
  final buffer = StringBuffer();
  for (final block in blocks) {
    final type = block['type'] as String;
    final richTexts = block[type]?['rich_text'] as List? ?? [];
    for (final rt in richTexts) {
      buffer.write(rt['plain_text'] ?? '');
    }
    buffer.writeln();
  }
  return buffer.toString().trim();
}

Future<void> _appendBlocks(
    http.Client client, String token, String pageId,
    List<Map<String, dynamic>> blocks) async {
  await client.patch(
    Uri.parse('https://api.notion.com/v1/blocks/$pageId/children'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Notion-Version': '2022-06-28',
    },
    body: jsonEncode({'children': blocks}),
  );
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 3)}...';

Map<String, dynamic> _heading2(String text) => {
      'object': 'block', 'type': 'heading_2',
      'heading_2': {'rich_text': [{'type': 'text', 'text': {'content': text}}]},
    };

Map<String, dynamic> _paragraph(String text) => {
      'object': 'block', 'type': 'paragraph',
      'paragraph': {'rich_text': [{'type': 'text', 'text': {'content': text}}]},
    };

Map<String, dynamic> _codeBlock(String code) => {
      'object': 'block', 'type': 'code',
      'code': {
        'rich_text': [{'type': 'text', 'text': {'content': code}}],
        'language': 'diff',
      },
    };

Map<String, dynamic> _divider() => {
      'object': 'block', 'type': 'divider', 'divider': {},
    };
