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

  void _editTask(int index, String newTitle) {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return; // Prevent saving empty task titles
    setState(() {
      _tasks[index].title = trimmed;
    });
    _controller.clear();
  }

  void _toggleTask(int index) {
    setState(() => _tasks[index].isDone = !_tasks[index].isDone);
  }

  void _deleteTask(int index) {
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

  void _showAddEditSheet({int? index}) {
    final isEditing = index != null;
    if (isEditing) {
      _controller.text = _tasks[index!].title; // Pre-fill for editing
    } else {
      _controller.clear(); // Clear for adding new task
    }

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
                decoration: InputDecoration(
                  hintText: isEditing ? 'Edit task' : 'What needs to be done?',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (value) {
                  if (isEditing) {
                    _editTask(index!, value);
                  } else {
                    _addTask(value);
                  }
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () {
                if (isEditing) {
                  _editTask(index!, _controller.text);
                } else {
                  _addTask(_controller.text);
                }
                Navigator.pop(ctx);
              },
              child: Text(isEditing ? 'Save' : 'Add'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      _controller.clear(); // Ensure controller is cleared after sheet closes
    });
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
        onPressed: () => _showAddEditSheet(), // Call without index for adding
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
            return await showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text("Confirm Deletion"),
                  content: Text("Are you sure you want to delete \"${task.title}\"?"),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text("Cancel"),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                      child: const Text("Delete"),
                    ),
                  ],
                );
              },
            );
          },
          onDismissed: (_) => _deleteTask(index),
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
            onTap: () => _showAddEditSheet(index: index), // Add this to enable editing on tap
          ),
        );
      },
    );
  }
}