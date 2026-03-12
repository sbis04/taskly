import 'package:flutter/material.dart';

void main() => runApp(const TasklyApp());

class TasklyApp extends StatelessWidget {
  const TasklyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taskly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A1A2E),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A1A2E),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const TaskListScreen(),
    );
  }
}

class Task {
  String title;
  bool isDone;
  final DateTime createdAt;

  Task({required this.title, this.isDone = false})
      : createdAt = DateTime.now();
}

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  final List<Task> _tasks = [];
  final _controller = TextEditingController();

  int get _doneCount => _tasks.where((t) => t.isDone).length;

  void _addTask(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    setState(() => _tasks.insert(0, Task(title: trimmed)));
    _controller.clear();
  }

  void _toggleTask(int index) {
    setState(() => _tasks[index].isDone = !_tasks[index].isDone);
  }

  // Renamed from _deleteTask to _performDeleteTask as it's the actual deletion logic
  void _performDeleteTask(int index) {
    final removed = _tasks[index];
    setState(() => _tasks.removeAt(index));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('"${removed.title}" deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => setState(() => _tasks.insert(index, removed)),
          ),
        ),
      );
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'What needs to be done?',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) {
                  _addTask(value);
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () {
                _addTask(_controller.text);
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Taskly'),
        centerTitle: false,
        actions: [
          if (_tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '$_doneCount / ${_tasks.length} done',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _tasks.isEmpty ? _buildEmpty(theme) : _buildList(theme),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddSheet,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 64,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'No tasks yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap + to add one',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 88),
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return Dismissible(
          key: ObjectKey(task),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            color: theme.colorScheme.error,
            child: Icon(Icons.delete_outline, color: theme.colorScheme.onError),
          ),
          confirmDismiss: (direction) async {
            final bool confirm = await showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text("Confirm Deletion"),
                  content: Text("Are you sure you want to delete \"${task.title}\"? You can undo this action immediately after deletion."),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false), // Cancel
                      child: const Text("Cancel"),
                    ),
                    FilledButton( // Use FilledButton for destructive action
                      onPressed: () => Navigator.of(context).pop(true), // Confirm
                      style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                      child: const Text("Delete"),
                    ),
                  ],
                );
              },
            );
            return confirm;
          },
          onDismissed: (_) => _performDeleteTask(index), // Call the actual deletion function here
          child: ListTile(
            leading: Checkbox(
              value: task.isDone,
              onChanged: (_) => _toggleTask(index),
              shape: const CircleBorder(),
            ),
            title: Text(
              task.title,
              style: task.isDone
                  ? TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: theme.colorScheme.outline,
                    )
                  : null,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          ),
        );
      },
    );
  }
}
