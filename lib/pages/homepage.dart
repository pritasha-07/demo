import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mediva/main.dart';
import 'package:path_provider/path_provider.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Set<DateTime> _selectedDates = {};
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Medicine Reminder'),
        actions: [
          IconButton(
            onPressed: () async {
              await NotificationService.instance.cancelAll();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('All notifications cleared')),
              );
            },
            icon: const Icon(Icons.notifications_off),
            tooltip: 'Clear all notifications',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildCalendar(),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Selected: ${_selectedDates.length} day(s)'),
                ),
                FilledButton(
                  onPressed: _selectedDates.isEmpty
                      ? null
                      : _openCreateReminder,
                  child: const Text('New reminder'),
                ),
              ],
            ),
          ),
          const Divider(height: 0),
          Expanded(child: _buildDayView()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => setState(() => _selectedDates.clear()),
        label: const Text('Clear selection'),
        icon: const Icon(Icons.clear),
      ),
    );
  }

  Widget _buildCalendar() {
    return TableCalendar(
      firstDay: DateTime.now(),
      lastDay: DateTime.now().add(const Duration(days: 31)),
      focusedDay: _focusedDay,
      selectedDayPredicate: (day) =>
          _selectedDates.any((d) => isSameDay(d, day)),
      calendarFormat: CalendarFormat.month,
      onDaySelected: (selectedDay, focusedDay) {
        setState(() {
          _selectedDay = selectedDay;
          _focusedDay = focusedDay;
          final dateOnly = DateUtils.dateOnly(selectedDay);
          if (_selectedDates.any((d) => isSameDay(d, dateOnly))) {
            _selectedDates.removeWhere((d) => isSameDay(d, dateOnly));
          } else {
            _selectedDates.add(dateOnly);
          }
        });
      },
      onPageChanged: (focusedDay) => _focusedDay = focusedDay,
      calendarStyle: const CalendarStyle(outsideDaysVisible: false),
    );
  }

  Widget _buildDayView() {
    return ValueListenableBuilder(
      valueListenable: StorageService.instance.reminders.listenable(),
      builder: (context, Box box, _) {
        final items = box.toMap().cast<int, Map>().map(
          (k, v) => MapEntry(k, Map<String, dynamic>.from(v)),
        );
        final todayKey = DateUtils.dateOnly(_selectedDay).toIso8601String();
        final logs = StorageService.instance.getAllLogs();
        final dayLog = logs[todayKey] ?? {};

        final todaysReminders =
            items.entries.where((e) {
              final dates = List<String>.from(
                e.value[ReminderFields.dates] as List,
              );
              final has = dates.contains(todayKey.substring(0, 10));
              return has;
            }).toList()..sort(
              (a, b) => (a.value[ReminderFields.time] as String).compareTo(
                b.value[ReminderFields.time] as String,
              ),
            );

        if (todaysReminders.isEmpty) {
          return const Center(child: Text('No reminders for this day.'));
        }

        return ListView.separated(
          itemCount: todaysReminders.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (context, i) {
            final id = todaysReminders[i].key;
            final data = todaysReminders[i].value;
            final status = dayLog[id.toString()];
            return ListTile(
              title: Text(data[ReminderFields.name] as String),
              subtitle: Text(
                'Time: ${data[ReminderFields.time]}  •  Status: ${status ?? 'pending'}',
              ),
              trailing: PopupMenuButton(
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'taken',
                    child: Text('Mark Taken'),
                  ),
                  const PopupMenuItem(
                    value: 'skipped',
                    child: Text('Mark Skipped'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete Reminder'),
                  ),
                ],
                onSelected: (value) async {
                  if (value == 'delete') {
                    await StorageService.instance.deleteReminder(id);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Reminder deleted')),
                    );
                  } else if (value == 'taken' || value == 'skipped') {
                    await StorageService.instance.setLog(
                      date: _selectedDay,
                      reminderId: id,
                      status: value as String,
                    );
                    if (!mounted) return;
                    setState(() {});
                  }
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openCreateReminder() async {
    final result = await showDialog<_CreateResult>(
      context: context,
      builder: (context) => _CreateReminderDialog(),
    );
    if (result == null) return;

    final id = StorageService.instance.nextId();
    final dateStrs = _selectedDates
        .map((d) => DateUtils.dateOnly(d))
        .map(
          (d) =>
              '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
        )
        .toList();

    final data = {
      ReminderFields.id: id,
      ReminderFields.name: result.name,
      ReminderFields.time: _formatTime(result.time),
      ReminderFields.dates: dateStrs,
    };

    await StorageService.instance.saveReminder(id, data);

    // Schedule notifications for each selected date
    for (final d in _selectedDates) {
      final scheduledAt = DateTime(
        d.year,
        d.month,
        d.day,
        result.time.hour,
        result.time.minute,
      );
      final payload = '$id|${DateUtils.dateOnly(d).toIso8601String()}';
      await NotificationService.instance.scheduleReminder(
        id: _notifId(id, d),
        title: 'Take ${result.name}',
        body: 'Tap an action to confirm.',
        scheduleAt: scheduledAt,
        payload: payload,
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Scheduled for ${_selectedDates.length} day(s)')),
    );
    setState(() {});
  }

  int _notifId(int reminderId, DateTime date) {
    // Create a unique notification ID per reminder per date: yyyymmdd * 1000 + reminderId (safe within 2^31)
    final d = DateUtils.dateOnly(date);
    final key = d.year * 10000 + d.month * 100 + d.day;
    return key * 1000 + reminderId;
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
