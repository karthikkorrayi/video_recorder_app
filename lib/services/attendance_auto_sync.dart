import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:excel/excel.dart';
import 'onedrive_service.dart';

/// Auto-updating admin attendance Excel on OneDrive.
///
/// ONE FILE: OTN Recorder/Attendance Reports/OTN_Attendance.xlsx
/// ONE SHEET PER DATE: "05 May 2026", "06 May 2026", etc.
/// All users' sessions in each sheet.
///
/// Flow (triggered after every chunk upload confirms):
///   1. Download existing OTN_Attendance.xlsx from OneDrive
///   2. Load it → find or create sheet for that date
///   3. Rebuild that date's sheet from Firestore (fresh, no duplication)
///   4. Re-upload (overwrites)
///
/// Admin opens: OneDrive → OTN Recorder → Attendance Reports → OTN_Attendance.xlsx
class AttendanceAutoSync {
  static final AttendanceAutoSync _i = AttendanceAutoSync._();
  factory AttendanceAutoSync() => _i;
  AttendanceAutoSync._();

  static const _odFolder   = 'OTN Recorder/Attendance Reports';
  static const _odFileName = 'OTN_Attendance.xlsx';

  // Debounce per date — multiple chunks finishing together = one rebuild
  final Map<String, Timer> _timers = {};
  static const _debounce = Duration(seconds: 8);

  // ── Called from main queue (debounced) ───────────────────────────────────
  void scheduleUpdate(String dateFolder) {
    _timers[dateFolder]?.cancel();
    _timers[dateFolder] = Timer(_debounce, () {
      buildAndUploadNow(dateFolder).catchError((dynamic e) {
        debugPrint('=== Attendance scheduleUpdate error: $e');
      });
    });
    debugPrint('=== Attendance: scheduled for $dateFolder');
  }

  // ── Called directly from WorkManager (awaited, no timer) ─────────────────
  Future<void> buildAndUploadNow(String dateFolder) async {
    try {
      await _buildAndUpload(dateFolder);
    } catch (e, st) {
      debugPrint('=== Attendance: buildAndUploadNow error: $e\n$st');
    }
  }

  // ── Core ─────────────────────────────────────────────────────────────────
  Future<void> _buildAndUpload(String dateFolder) async {
    debugPrint('=== Attendance: building for $dateFolder');

    // ── 1. Query Firestore for this date ─────────────────────────────────
    final sessions = await _querySessions(dateFolder);
    if (sessions.isEmpty) {
      debugPrint('=== Attendance: no sessions for $dateFolder — skip');
      return;
    }
    debugPrint('=== Attendance: ${sessions.length} sessions found');

    // Sort by userFolder then sessionStartMs
    sessions.sort((a, b) {
      final u = (a['userFolder'] as String? ?? '')
          .compareTo(b['userFolder'] as String? ?? '');
      if (u != 0) return u;
      return ((a['sessionStartMs'] as int? ?? 0))
          .compareTo(b['sessionStartMs'] as int? ?? 0);
    });

    // ── 2. Download existing Excel from OneDrive (or create new) ─────────
    final od    = OneDriveService();
    final bytes = await od.downloadFileBytes(
        folderPath: _odFolder, fileName: _odFileName);

    Excel excel;
    if (bytes != null) {
      try {
        excel = Excel.decodeBytes(bytes);
        // Remove default sheet if it crept in
        if (excel.sheets.containsKey('Sheet1') && excel.sheets.length > 1) {
          excel.delete('Sheet1');
        }
        debugPrint('=== Attendance: loaded existing workbook from OneDrive');
      } on Exception catch (e) {
        debugPrint('=== Attendance: decode Exception ($e) — new workbook');
        excel = Excel.createExcel(); excel.delete('Sheet1');
      } on Error catch (e) {
        // UnsupportedError, StateError etc — non-xlsx bytes from OneDrive
        debugPrint('=== Attendance: decode Error ($e) — new workbook');
        excel = Excel.createExcel(); excel.delete('Sheet1');
      }
    } else {
      excel = Excel.createExcel();
      excel.delete('Sheet1');
      debugPrint('=== Attendance: creating new workbook');
    }

    // ── 3. Ensure Overview sheet exists ───────────────────────────────────
    if (!excel.sheets.containsKey('Overview')) {
      _buildOverviewHeader(excel['Overview']);
    }

    // ── 4. Rebuild this date's sheet (always fresh — no duplicates) ───────
    final sheetName = _sheetName(dateFolder);
    // Delete old version of this sheet if exists (fresh rebuild)
    if (excel.sheets.containsKey(sheetName)) {
      excel.delete(sheetName);
    }
    final ws = excel[sheetName];
    _buildDateSheet(ws, dateFolder, sheetName, sessions);

    // ── 5. Update overview row for this date ──────────────────────────────
    _upsertOverviewRow(excel['Overview'], dateFolder, sheetName, sessions);

    // ── 6. Encode → temp file → upload ───────────────────────────────────
    final encoded = excel.encode();
    if (encoded == null) {
      debugPrint('=== Attendance: encode returned null — abort');
      return;
    }

    final tmp      = await getTemporaryDirectory();
    final filePath = '${tmp.path}/$_odFileName';
    await File(filePath).writeAsBytes(encoded);

    try {
      debugPrint('=== Attendance: uploading $_odFileName to OneDrive...');
      await od.uploadToAttendanceFolder(
        filePath:   filePath,
        fileName:   _odFileName,
        onProgress: (p) => debugPrint('=== Attendance: ${(p * 100).toInt()}%'),
        onStatus:   (_) {},
      );
      debugPrint('=== Attendance: ✓ uploaded $_odFileName');
    } catch (e, st) {
      debugPrint('=== Attendance: upload FAILED: $e\n$st');
    } finally {
      try { File(filePath).deleteSync(); } catch (_) {}
    }
  }

  // ── Query Firestore with collectionGroup + fallback ───────────────────────
  Future<List<Map<String, dynamic>>> _querySessions(String dateFolder) async {
    final sessions = <Map<String, dynamic>>[];
    try {
      final snap = await FirebaseFirestore.instance
          .collectionGroup('sessions')
          .where('dateFolder', isEqualTo: dateFolder)
          .get()
          .timeout(const Duration(seconds: 30));
      for (final d in snap.docs) { sessions.add(d.data()); }
      debugPrint('=== Attendance: collectionGroup got ${sessions.length} docs');
    } catch (e) {
      debugPrint('=== Attendance: collectionGroup failed ($e) — fallback');
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return sessions;
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('sessions')
          .where('dateFolder', isEqualTo: dateFolder)
          .get()
          .timeout(const Duration(seconds: 30));
      for (final d in snap.docs) { sessions.add(d.data()); }
      debugPrint('=== Attendance: fallback got ${sessions.length} docs');
    }
    return sessions;
  }

  // ── Build one date sheet ──────────────────────────────────────────────────
  void _buildDateSheet(Sheet ws, String dateFolder, String sheetName,
      List<Map<String, dynamic>> sessions) {
    final generated = DateFormat('dd MMM yyyy, HH:mm:ss').format(DateTime.now());

    // Row 0: Main title
    _c(ws, 0, 0, 'OTN VIDEO RECORDER — ATTENDANCE REPORT',
        bg: _navy, fg: _green, bold: true, sz: 14, span: 9);

    // Row 1: Date + generated time
    _c(ws, 1, 0, '$sheetName   |   Generated: $generated',
        bg: _subHdr, fg: _white, sz: 10, span: 9);

    // Row 2: column headers
    const hdrs = ['#', 'User Name', 'Session ID', 'Date',
                   'Start Time', 'Duration', 'Chunks', 'Status', 'Notes'];
    for (var i = 0; i < hdrs.length; i++) {
      _c(ws, 2, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }

    ws.setColumnWidth(0, 5);
    ws.setColumnWidth(1, 24);
    ws.setColumnWidth(2, 16);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 14);
    ws.setColumnWidth(5, 18);  // wider for "1h 20m 35s"
    ws.setColumnWidth(6, 10);
    ws.setColumnWidth(7, 14);
    ws.setColumnWidth(8, 28);

    // Data rows — group by user
    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final s in sessions) {
      final u = s['userFolder'] as String? ?? 'Unknown';
      byUser.putIfAbsent(u, () => []).add(s);
    }

    var row    = 3;
    var seqNum = 1;
    var altBg  = false;

    for (final entry in byUser.entries) {
      final name  = entry.key;
      final rows  = entry.value;
      final rowBg = altBg ? _rowAlt : _rowMain;
      altBg = !altBg;

      for (var si = 0; si < rows.length; si++) {
        final s        = rows[si];
        final secs     = s['totalSecs']      as int? ?? 0;
        final chunks   = s['chunksUploaded'] as int? ?? 0;
        final status   = s['status']         as String? ?? 'uploading';
        final startMs  = s['sessionStartMs'] as int? ?? 0;
        final rawId    = s['sessionId']      as String? ?? '';
        final sid      = rawId.length >= 8
            ? rawId.substring(0, 8).toUpperCase() : rawId.toUpperCase();
        final startDt  = startMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(startMs) : null;
        final startStr = startDt != null
            ? DateFormat('HH:mm:ss').format(startDt) : '--';
        final dateStr  = startDt != null
            ? DateFormat('dd-MM-yyyy').format(startDt) : dateFolder;
        final isSynced = status == 'synced';
        final statusLbl = isSynced ? '✓ Uploaded' : '⏳ Uploading';
        final statusFg  = isSynced ? _darkGrn : _orange;
        final note      = isSynced ? '' : 'Upload in progress';

        _c(ws, row, 0, seqNum,          bg: rowBg);
        _c(ws, row, 1, si == 0 ? name : '', bg: rowBg,
            fg: si == 0 ? _text : _grey, bold: si == 0);
        _c(ws, row, 2, sid,             bg: rowBg);
        _c(ws, row, 3, dateStr,         bg: rowBg);
        _c(ws, row, 4, startStr,        bg: rowBg);
        _c(ws, row, 5, _fmt(secs),      bg: rowBg, fg: _text, bold: true);
        _c(ws, row, 6, chunks,          bg: rowBg);
        _c(ws, row, 7, statusLbl,       bg: rowBg, fg: statusFg, bold: true);
        _c(ws, row, 8, note,            bg: rowBg, fg: _grey);

        row++;
        seqNum++;
      }

      // User subtotal
      final subSecs   = rows.fold<int>(0, (s, d) => s + (d['totalSecs']      as int? ?? 0));
      final subChunks = rows.fold<int>(0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
      _c(ws, row, 0, '',              bg: _subtotalBg);
      _c(ws, row, 1, '$name  (${rows.length} session${rows.length == 1 ? '' : 's'})',
          bg: _subtotalBg, fg: _subtotalFg, bold: true);
      _c(ws, row, 2, '',              bg: _subtotalBg);
      _c(ws, row, 3, '',              bg: _subtotalBg);
      _c(ws, row, 4, '',              bg: _subtotalBg);
      _c(ws, row, 5, _fmt(subSecs),  bg: _subtotalBg, fg: _subtotalFg, bold: true);
      _c(ws, row, 6, subChunks,      bg: _subtotalBg, fg: _subtotalFg, bold: true);
      _c(ws, row, 7, '',              bg: _subtotalBg);
      _c(ws, row, 8, '',              bg: _subtotalBg);
      row++;
    }

    // Grand total
    row++;
    final grandSecs   = sessions.fold<int>(0, (s, d) => s + (d['totalSecs']      as int? ?? 0));
    final grandChunks = sessions.fold<int>(0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
    final userCount   = byUser.keys.length;
    _c(ws, row, 0, 'GRAND TOTAL',   bg: _green, fg: _white, bold: true, span: 2);
    _c(ws, row, 1, '',               bg: _green);
    _c(ws, row, 2, '${sessions.length} sessions', bg: _green, fg: _white, bold: true);
    _c(ws, row, 3, '$userCount users', bg: _green, fg: _white, bold: true);
    _c(ws, row, 4, '',               bg: _green);
    _c(ws, row, 5, _fmt(grandSecs), bg: _green, fg: _white, bold: true, sz: 11);
    _c(ws, row, 6, grandChunks,     bg: _green, fg: _white, bold: true);
    _c(ws, row, 7, '',               bg: _green);
    _c(ws, row, 8, '',               bg: _green);
  }

  // ── Overview sheet ────────────────────────────────────────────────────────
  void _buildOverviewHeader(Sheet ws) {
    _c(ws, 0, 0, 'OTN RECORDER — ALL DATES OVERVIEW',
        bg: _navy, fg: _green, bold: true, sz: 13, span: 6);
    _c(ws, 1, 0, 'Auto-updated on every upload. Open individual date sheets for details.',
        bg: _subHdr, fg: _white, span: 6);
    const hdrs = ['Date', 'Sessions', 'Total Duration', 'Total Chunks', 'Users', 'Last Updated'];
    for (var i = 0; i < hdrs.length; i++) {
      _c(ws, 2, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }
    ws.setColumnWidth(0, 16);
    ws.setColumnWidth(1, 12);
    ws.setColumnWidth(2, 18);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 30);
    ws.setColumnWidth(5, 22);
  }

  void _upsertOverviewRow(Sheet ws, String dateFolder, String sheetName,
      List<Map<String, dynamic>> sessions) {
    // Find existing row for this date or append
    int? existingRow;
    for (var r = 3; r < ws.maxRows; r++) {
      final cell = ws.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
      final val  = cell.value;
      if (val is TextCellValue && val.value.text == dateFolder) {
        existingRow = r; break;
      }
    }
    final row        = existingRow ?? ws.maxRows;
    final isAlt      = (row - 3) % 2 == 0;
    final bg         = isAlt ? _rowMain : _rowAlt;
    final grandSecs  = sessions.fold<int>(0, (s, d) => s + (d['totalSecs'] as int? ?? 0));
    final grandChunks= sessions.fold<int>(0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
    final users      = sessions.map((d) => d['userFolder'] as String? ?? '').toSet().join(', ');
    final now        = DateFormat('dd MMM HH:mm').format(DateTime.now());

    _c(ws, row, 0, dateFolder,       bg: bg);
    _c(ws, row, 1, sessions.length,  bg: bg);
    _c(ws, row, 2, _fmt(grandSecs),  bg: bg, bold: true);
    _c(ws, row, 3, grandChunks,      bg: bg);
    _c(ws, row, 4, users,            bg: bg);
    _c(ws, row, 5, now,              bg: bg);
  }

  // ── Duration with seconds ─────────────────────────────────────────────────
  String _fmt(int secs) {
    if (secs <= 0) return '0s';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _sheetName(String folder) {
    try {
      final p  = folder.split('-');
      final dt = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      return DateFormat('dd MMM yyyy').format(dt);
    } catch (_) { return folder; }
  }

  // ── Colors ────────────────────────────────────────────────────────────────
  static const _navy       = '#1A1A2E';
  static const _subHdr     = '#16213E';
  static const _hdrBg      = '#0F3460';
  static const _green      = '#00C853';
  static const _darkGrn    = '#2E7D32';
  static const _orange     = '#E65100';
  static const _white      = '#FFFFFF';
  static const _text       = '#1A1A1A';
  static const _grey       = '#888888';
  static const _rowMain    = '#E8F5E9';
  static const _rowAlt     = '#F1F8E9';
  static const _subtotalBg = '#C8E6C9';
  static const _subtotalFg = '#1B5E20';
  static const _border     = '#C8E6C9';

  // ── Cell builder ─────────────────────────────────────────────────────────
  void _c(Sheet ws, int row, int col, dynamic value, {
    String bg   = '#FFFFFF',
    String fg   = '#1A1A1A',
    bool   bold = false,
    double sz   = 10,
    int    span = 1,
  }) {
    final idx  = CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);
    final cell = ws.cell(idx);
    if (value is int) {
      cell.value = IntCellValue(value);
    } else if (value is double) {
      cell.value = DoubleCellValue(value);
    } else {
      cell.value = TextCellValue(value.toString());
    }
    cell.cellStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString(bg),
      fontColorHex:       ExcelColor.fromHexString(fg),
      bold:               bold,
      fontSize:           sz.toInt(),
      horizontalAlign:    HorizontalAlign.Center,
      verticalAlign:      VerticalAlign.Center,
      leftBorder:   Border(borderStyle: BorderStyle.Thin,
          borderColorHex: ExcelColor.fromHexString(_border)),
      rightBorder:  Border(borderStyle: BorderStyle.Thin,
          borderColorHex: ExcelColor.fromHexString(_border)),
      topBorder:    Border(borderStyle: BorderStyle.Thin,
          borderColorHex: ExcelColor.fromHexString(_border)),
      bottomBorder: Border(borderStyle: BorderStyle.Thin,
          borderColorHex: ExcelColor.fromHexString(_border)),
    );
    if (span > 1) {
      ws.merge(idx, CellIndex.indexByColumnRow(
          columnIndex: col + span - 1, rowIndex: row));
    }
  }
}