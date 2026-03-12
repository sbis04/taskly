import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
  DateTime? reminderDateTime; // Added field for reminder

  Task({required this.title, this.isDone = false, this.reminderDateTime})
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

  Future<void> _pickReminderDateTime(int index) async {
    final initialDate = _tasks[index].reminderDateTime ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)), // 5 years from now
    );

    if (pickedDate == null) return; // User canceled date picker

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );

    if (pickedTime == null) return; // User canceled time picker

    setState(() {
      _tasks[index].reminderDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
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
            subtitle: task.reminderDateTime != null
                ? Text(
                    'Reminder: ${DateFormat('MMM d, yyyy HH:mm').format(task.reminderDateTime!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  )
                : null,
            trailing: IconButton(
              icon: Icon(
                task.reminderDateTime != null ? Icons.alarm_on : Icons.alarm_add,
                color: task.reminderDateTime != null ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: () => _pickReminderDateTime(index),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
          ),
        );
      },
    );
  }
}
