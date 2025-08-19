// ============================
// pubspec.yaml (add these)
// ============================
// dependencies:
//   flutter:
//     sdk: flutter
//   flutter_local_notifications: ^17.2.1
//   timezone: ^0.9.4
//   table_calendar: ^3.0.9
//   hive: ^2.2.3
//   hive_flutter: ^1.1.0
//   path_provider: ^2.1.4
//
// ============================
// ANDROID SETUP
// ============================
// 1) android/app/src/main/AndroidManifest.xml inside <application> add:
//  <receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver" android:exported="false">
//    <intent-filter>
//      <action android:name="android.intent.action.BOOT_COMPLETED"/>
//      <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
//    </intent-filter>
//  </receiver>
//  <receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" android:exported="false" />
//  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" /> <!-- Android 13+ runtime permission still required -->
//
// 2) For Android 13+ request POST_NOTIFICATIONS at runtime (handled in code).
//
// ============================
// iOS SETUP
// ============================
// - In Xcode, enable Push Notifications and Background Modes > Background fetch + Remote notifications.
// - Add notification categories in the initialization below; request permissions at first launch.
//
// ============================
// main.dart (single-file demo app)
// Features:
// - Monthly calendar (TableCalendar) with multi-select dates (up to 31 days ahead)
// - Create medicine reminder for selected dates at a chosen time
// - Schedules local notifications with action buttons: "TAKEN" and "SKIP"
// - Tapping an action records status for that date in Hive
// - Day view shows status per reminder
//
// Note: This is a minimal working example. For production, split into files and add error handling.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

// part 'main.g.dart'; // ignored at runtime; kept to suggest codegen if you later add adapters

// --------------------
// Simple models stored in Hive as Maps
// --------------------
class ReminderFields {
  static const id = 'id';
  static const name = 'name';
  static const time = 'time'; // "HH:mm"
  static const dates = 'dates'; // List<String> yyyy-MM-dd
}

class LogFields {
  static const key =
      'logs'; // box key -> Map<String dateISO, Map<reminderId, status>>
}

// --------------------
// Notification Service
// --------------------
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String channelId = 'meds_channel';
  static const String channelName = 'Medicine Reminders';
  static const String channelDesc = 'Scheduled medicine intake reminders';

  static const String actionTaken = 'TAKEN_ACTION';
  static const String actionSkip = 'SKIP_ACTION';

  Future<void> init(Function(NotificationResponse) onAction) async {
    tz.initializeTimeZones();
    final local = await tz.getLocation(await _deviceTimeZone());
    tz.setLocalLocation(local);

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

    final darwinInit = DarwinInitializationSettings(
      onDidReceiveLocalNotification: (id, title, body, payload) async {},
      notificationCategories: [
        DarwinNotificationCategory(
          'demoCategory',
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(
              'id_1',
              'Open',
              options: {DarwinNotificationActionOption.foreground},
            ),
            DarwinNotificationAction.plain(
              'id_2',
              'Dismiss',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
      ],
    );

    final initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: onAction,
    );

    // Android channel
    const androidChannel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDesc,
      importance: Importance.max,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);
  }

  Future<void> requestPermissions() async {
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduleAt,
    required String payload,
  }) async {
    final tzDate = tz.TZDateTime.from(scheduleAt, tz.local);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzDate,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDesc,
          category: AndroidNotificationCategory.reminder,
          priority: Priority.high,
          importance: Importance.max,
          actions: [
            const AndroidNotificationAction(
              NotificationService.actionTaken,
              'Taken',
            ),
            const AndroidNotificationAction(
              NotificationService.actionSkip,
              'Skip',
            ),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          categoryIdentifier: 'MEDS_CATEGORY',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
      matchDateTimeComponents: null,
    );
  }

  Future<void> cancelById(int id) => _plugin.cancel(id);

  Future<void> cancelAll() => _plugin.cancelAll();

  Future<String> _deviceTimeZone() async {
    // flutter_local_notifications uses native timezone by default;
    // tz.getLocation expects a valid name. As a safe default, return "Asia/Kolkata".
    // You can integrate native_timezone package if needed.
    return 'Asia/Kolkata';
  }
}

// --------------------
// Hive helpers
// --------------------
class StorageService {
  StorageService._();
  static final instance = StorageService._();

  late Box reminders; // key: reminderId -> Map
  late Box logs; // key: LogFields.key -> Map

  Future<void> init() async {
    await Hive.initFlutter();
    reminders = await Hive.openBox('reminders');
    logs = await Hive.openBox('logs');
    final logData = logs.get(LogFields.key, defaultValue: <String, Map<String, String>>{});
  }

  int nextId() {
    final keys = reminders.keys.whereType<int>().toList();
    if (keys.isEmpty) return 1;
    keys.sort();
    return keys.last + 1;
  }

  Future<void> saveReminder(int id, Map<String, dynamic> data) async {
    await reminders.put(id, data);
  }

  Map<String, dynamic>? getReminder(int id) {
    final v = reminders.get(id);
    if (v == null) return null;
    return Map<String, dynamic>.from(v as Map);
  }

  Future<void> deleteReminder(int id) async {
    await reminders.delete(id);
  }

  Map<String, Map<String, String>> getAllLogs() {
    final v = logs.get(LogFields.key) as Map;
    return v.map(
      (k, v) => MapEntry(k as String, Map<String, String>.from(v as Map)),
    );
  }

  Future<void> setLog({
    required DateTime date,
    required int reminderId,
    required String status,
  }) async {
    final key = _dateKey(date);
    final current = getAllLogs();
    final dayMap = Map<String, String>.from(current[key] ?? {});
    dayMap[reminderId.toString()] = status; // 'taken' | 'skipped'
    current[key] = dayMap;
    await logs.put(LogFields.key, current);
  }

  String _dateKey(DateTime d) => DateUtils.dateOnly(d).toIso8601String();
}

// --------------------
// App
// --------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService.instance.init();
  await NotificationService.instance.init(_onAction);
  await NotificationService.instance.requestPermissions();
  runApp(const MedsApp());
}

void _onAction(NotificationResponse response) async {
  try {
    final payload = response.payload ?? '';
    // payload format: "<reminderId>|<yyyy-MM-dd>"
    final parts = payload.split('|');
    if (parts.length != 2) return;
    final reminderId = int.parse(parts[0]);
    final date = DateTime.parse(parts[1]);

    if (response.actionId == NotificationService.actionTaken) {
      await StorageService.instance.setLog(
        date: date,
        reminderId: reminderId,
        status: 'taken',
      );
    } else if (response.actionId == NotificationService.actionSkip) {
      await StorageService.instance.setLog(
        date: date,
        reminderId: reminderId,
        status: 'skipped',
      );
    }
  } catch (_) {}
}

class MedsApp extends StatelessWidget {
  const MedsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medicine Reminder',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

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

class _CreateResult {
  final String name;
  final TimeOfDay time;
  _CreateResult(this.name, this.time);
}

class _CreateReminderDialog extends StatefulWidget {
  @override
  State<_CreateReminderDialog> createState() => _CreateReminderDialogState();
}

class _CreateReminderDialogState extends State<_CreateReminderDialog> {
  final _form = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  TimeOfDay _time = TimeOfDay.now();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Reminder'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Medicine name'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Time:'),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _time,
                    );
                    if (picked != null) setState(() => _time = picked);
                  },
                  child: Text(
                    '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_form.currentState!.validate()) {
              Navigator.pop(
                context,
                _CreateResult(_nameCtrl.text.trim(), _time),
              );
            }
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
