import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DateRange {
  final DateTime start;
  final DateTime end;
  final String label;
  const DateRange({required this.start, required this.end, required this.label});

  bool contains(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return !d.isBefore(s) && !d.isAfter(e);
  }

  static DateRange allTime() =>
      DateRange(start: DateTime(2000), end: DateTime(2100), label: 'All Time');
}

enum FilterMode { allTime, year, month, week, day, custom }

class DateFilterState {
  final FilterMode mode;
  final DateTime focusDate;
  final DateRange? customRange;

  const DateFilterState({
    this.mode = FilterMode.allTime,
    required this.focusDate,
    this.customRange,
  });

  String get label {
    switch (mode) {
      case FilterMode.allTime: return 'All Time';
      case FilterMode.year:    return DateFormat('yyyy').format(focusDate);
      case FilterMode.month:   return DateFormat('MMM yyyy').format(focusDate);
      case FilterMode.week:
        final ws = _weekStart(focusDate);
        final we = ws.add(const Duration(days: 6));
        return '${DateFormat('d MMM').format(ws)}–${DateFormat('d MMM').format(we)}';
      case FilterMode.day:     return DateFormat('d MMM yyyy').format(focusDate);
      case FilterMode.custom:
        if (customRange == null) return 'Custom';
        return '${DateFormat('d MMM').format(customRange!.start)}–'
               '${DateFormat('d MMM').format(customRange!.end)}';
    }
  }

  DateRange get range {
    switch (mode) {
      case FilterMode.allTime: return DateRange.allTime();
      case FilterMode.year:
        return DateRange(
          start: DateTime(focusDate.year, 1, 1),
          end:   DateTime(focusDate.year, 12, 31),
          label: label);
      case FilterMode.month:
        return DateRange(
          start: DateTime(focusDate.year, focusDate.month, 1),
          end:   DateTime(focusDate.year, focusDate.month + 1, 0),
          label: label);
      case FilterMode.week:
        final ws = _weekStart(focusDate);
        return DateRange(start: ws, end: ws.add(const Duration(days: 6)), label: label);
      case FilterMode.day:
        return DateRange(
          start: DateTime(focusDate.year, focusDate.month, focusDate.day),
          end:   DateTime(focusDate.year, focusDate.month, focusDate.day),
          label: label);
      case FilterMode.custom:
        return customRange ?? DateRange.allTime();
    }
  }

  static DateTime _weekStart(DateTime d) =>
      DateTime(d.year, d.month, d.day - (d.weekday - 1));
}

// ── DateFilterBar ─────────────────────────────────────────────────────────────
class DateFilterBar extends StatelessWidget {
  final DateFilterState state;
  final ValueChanged<DateFilterState> onChanged;
  final Color accent;

  const DateFilterBar({
    super.key,
    required this.state,
    required this.onChanged,
    this.accent = const Color(0xFF00C853),
  });

  static const _modes = [
    (FilterMode.allTime, 'All',   Icons.all_inclusive_rounded),
    (FilterMode.year,    'Year',  Icons.event_note_outlined),
    (FilterMode.month,   'Month', Icons.calendar_month_outlined),
    (FilterMode.week,    'Week',  Icons.date_range_outlined),
    (FilterMode.day,     'Day',   Icons.today_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Mode pills
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(children: [
            ..._modes.map((m) => _ModeChip(
              label: m.$2, icon: m.$3,
              active: state.mode == m.$1,
              accent: accent,
              onTap: () => onChanged(DateFilterState(
                  mode: m.$1, focusDate: DateTime.now())),
            )),
            _ModeChip(
              label: 'Custom', icon: Icons.tune_rounded,
              active: state.mode == FilterMode.custom,
              accent: accent,
              onTap: () => _pickCustomRange(context),
            ),
          ]),
        ),
        // Navigation row
        if (state.mode != FilterMode.allTime && state.mode != FilterMode.custom)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
            child: Row(children: [
              _NavBtn(Icons.chevron_left, accent, () => _shift(-1)),
              Expanded(child: GestureDetector(
                onTap: () => _pickDate(context),
                child: Center(child: Text(state.label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: accent))),
              )),
              _NavBtn(Icons.chevron_right, accent, () => _shift(1)),
            ]),
          ),
        if (state.mode == FilterMode.custom && state.customRange != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
            child: Center(child: Text(state.label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                    color: accent))),
          ),
      ]),
    );
  }

  void _shift(int delta) {
    DateTime next;
    switch (state.mode) {
      case FilterMode.year:
        next = DateTime(state.focusDate.year + delta); break;
      case FilterMode.month:
        next = DateTime(state.focusDate.year, state.focusDate.month + delta); break;
      case FilterMode.week:
        next = state.focusDate.add(Duration(days: 7 * delta)); break;
      case FilterMode.day:
        next = state.focusDate.add(Duration(days: delta)); break;
      default: return;
    }
    onChanged(DateFilterState(mode: state.mode, focusDate: next));
  }

  Future<void> _pickDate(BuildContext ctx) async {
    final picked = await showDatePicker(
      context: ctx,
      initialDate: state.focusDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (c, child) => Theme(
        data: Theme.of(c).copyWith(
            colorScheme: ColorScheme.light(primary: accent)),
        child: child!),
    );
    if (picked != null) {
      onChanged(DateFilterState(mode: state.mode, focusDate: picked));
    }
  }

  Future<void> _pickCustomRange(BuildContext ctx) async {
    final picked = await showDateRangePicker(
      context: ctx,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: state.customRange != null
          ? DateTimeRange(start: state.customRange!.start, end: state.customRange!.end)
          : null,
      builder: (c, child) => Theme(
        data: Theme.of(c).copyWith(
            colorScheme: ColorScheme.light(primary: accent)),
        child: child!),
    );
    if (picked != null) {
      onChanged(DateFilterState(
          mode: FilterMode.custom,
          focusDate: picked.start,
          customRange: DateRange(
              start: picked.start, end: picked.end, label: 'Custom')));
    }
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final Color accent;
  final VoidCallback onTap;
  const _ModeChip({required this.label, required this.icon,
      required this.active, required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? accent : const Color(0xFFF4F6F8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: active ? accent : const Color(0xFFE0E0E0))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: active ? Colors.white : const Color(0xFF888888)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF888888))),
      ]),
    ),
  );
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _NavBtn(this.icon, this.color, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0))),
      child: Icon(icon, size: 18, color: color),
    ),
  );
}