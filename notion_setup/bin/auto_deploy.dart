import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/notion_client.dart';

/// Called by GitHub Action after investigation to apply changes, create branch + PR.
/// Reads .ghost_changes.json from the investigate step, applies changes,
/// commits, pushes, and creates a PR.
///
/// Expects env vars: NOTION_TOKEN, NOTION_DATABASE_ID, GITHUB_TOKEN,
///   ISSUE_TITLE, ISSUE_NUMBER, GITHUB_WORKSPACE, TARGET_REPO
void main() async {
  final notionToken = Platform.environment['NOTION_TOKEN']!;
  final databaseId = Platform.environment['NOTION_DATABASE_ID']!;
  final githubToken = Platform.environment['GITHUB_TOKEN']!;
  final issueTitle = Platform.environment['ISSUE_TITLE'] ?? '';
  final issueNumberStr = Platform.environment['ISSUE_NUMBER'] ?? '0';
  final workspace = Platform.environment['GITHUB_WORKSPACE'] ?? '.';
  final targetRepo = Platform.environment['TARGET_REPO'] ?? '';

  final issueNumber = int.tryParse(issueNumberStr) ?? 0;
  final notionClient = NotionClient(token: notionToken);
  final httpClient = http.Client();

  // 1. Read the proposed changes
  final changesFile = File('$workspace/.ghost_changes.json');
  if (!changesFile.existsSync()) {
    stderr.writeln('.ghost_changes.json not found. Run auto_investigate first.');
    exit(1);
  }

  final changesData =
      jsonDecode(changesFile.readAsStringSync()) as Map<String, dynamic>;
  final changes = changesData['changes'] as List;
  final explanation = changesData['explanation'] as String? ?? '';
  final confidence = changesData['confidence'] as int? ?? 0;

  if (changes.isEmpty) {
    print('No changes proposed. Skipping deploy.');
    exit(0);
  }

  // 2. Find the Notion page
  final pages = await notionClient.queryDatabase(
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

  // 3. Apply changes to local files
  print('Applying ${changes.length} file changes...');
  final changedFiles = <String>[];

  for (final change in changes) {
    final filePath = change['file'] as String;
    final newContent = change['new_content'] as String;
    final fullPath = '$workspace/$filePath';

    // Ensure directory exists
    final dir = Directory(fullPath.substring(0, fullPath.lastIndexOf('/')));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    File(fullPath).writeAsStringSync(newContent);
    changedFiles.add(filePath);
    print('  ✓ $filePath');
  }

  // 4. Create branch, commit, push using git
  final branchName = 'ghost/fix-issue-$issueNumber';

  print('Creating branch: $branchName');
  await _run('git', ['config', 'user.name', 'Ghost Maintainer'], workspace);
  await _run('git', ['config', 'user.email', 'ghost-maintainer@noreply.github.com'], workspace);
  await _run('git', ['checkout', '-b', branchName], workspace);
  await _run('git', ['add', ...changedFiles], workspace);
  await _run('git', [
    'commit',
    '-m',
    'fix: $issueTitle (#$issueNumber)\n\nAI-proposed fix by Ghost Maintainer\nConfidence: $confidence%',
  ], workspace);

  // Push using the token
  final repoUrl = 'https://x-access-token:$githubToken@github.com/$targetRepo.git';
  await _run('git', ['push', repoUrl, branchName], workspace);
  print('Pushed to $branchName');

  // 5. Create PR via GitHub API
  print('Creating pull request...');
  final prBody = '''## Ghost Maintainer Fix

Automated fix for #$issueNumber: $issueTitle

### What changed
${changedFiles.map((f) => '- `$f`').join('\n')}

### AI Analysis
$explanation

### Confidence: $confidence%

---
*Created automatically by [Ghost Maintainer](https://github.com) — review carefully before merging.*''';

  // Get default branch
  final repoResponse = await httpClient.get(
    Uri.parse('https://api.github.com/repos/$targetRepo'),
    headers: {
      'Authorization': 'token $githubToken',
      'Accept': 'application/vnd.github.v3+json',
    },
  );
  final repoData = jsonDecode(repoResponse.body) as Map<String, dynamic>;
  final defaultBranch = repoData['default_branch'] as String;

  final prResponse = await httpClient.post(
    Uri.parse('https://api.github.com/repos/$targetRepo/pulls'),
    headers: {
      'Authorization': 'token $githubToken',
      'Accept': 'application/vnd.github.v3+json',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'title': 'fix: $issueTitle (#$issueNumber)',
      'body': prBody,
      'head': branchName,
      'base': defaultBranch,
    }),
  );

  if (prResponse.statusCode != 201) {
    stderr.writeln('Failed to create PR: ${prResponse.statusCode} ${prResponse.body}');
    exit(1);
  }

  final prData = jsonDecode(prResponse.body) as Map<String, dynamic>;
  final prUrl = prData['html_url'] as String;
  print('PR created: $prUrl');

  // 6. Update Notion with PR link
  await notionClient.updatePage(pageId, properties: {
    'Stage': {'select': {'name': 'Deploy'}},
    'PR URL': {'url': prUrl},
  });

  // Append deployment info to Notion page
  await httpClient.patch(
    Uri.parse('https://api.notion.com/v1/blocks/$pageId/children'),
    headers: {
      'Authorization': 'Bearer $notionToken',
      'Content-Type': 'application/json',
      'Notion-Version': '2022-06-28',
    },
    body: jsonEncode({
      'children': [
        {
          'object': 'block', 'type': 'heading_2',
          'heading_2': {'rich_text': [{'type': 'text', 'text': {'content': 'Deployment'}}]},
        },
        {
          'object': 'block', 'type': 'paragraph',
          'paragraph': {'rich_text': [{'type': 'text', 'text': {'content': 'PR: $prUrl'}}]},
        },
        {
          'object': 'block', 'type': 'paragraph',
          'paragraph': {'rich_text': [{'type': 'text', 'text': {'content': 'Branch: $branchName'}}]},
        },
      ],
    }),
  );

  print('Notion updated. Stage set to Deploy.');
  print('Done! Human reviewer can now review the PR.');

  // Cleanup
  changesFile.deleteSync();
  httpClient.close();
  notionClient.dispose();
}

Future<void> _run(String cmd, List<String> args, String workDir) async {
  final result = await Process.run(cmd, args, workingDirectory: workDir);
  if (result.exitCode != 0) {
    stderr.writeln('Command failed: $cmd ${args.join(' ')}');
    stderr.writeln(result.stderr);
    // Don't exit — some git commands may warn but succeed
  }
  if ((result.stdout as String).isNotEmpty) {
    print(result.stdout);
  }
}
