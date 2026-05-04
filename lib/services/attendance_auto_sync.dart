import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:excel/excel.dart';
import 'onedrive_service.dart';

// ─── AttendanceAutoSync ────────────────────────────────────────────────────
// Triggered automatically after every chunk upload completes.
// Reads ALL users' sessions for a date from Firestore,
// builds a master Excel, and uploads to:
//   OTN Recorder/Attendance Reports/OTN_Attendance_DD-MM-YYYY.xlsx
//
// Admin opens OneDrive → always sees up-to-date attendance for every user.
// No export button. No manual action needed.
class AttendanceAutoSync {
  static final AttendanceAutoSync _i = AttendanceAutoSync._();
  factory AttendanceAutoSync() => _i;
  AttendanceAutoSync._();

  // Debounce per date — if 3 chunks finish in 10s for the same date,
  // only one Excel rebuild happens.
  final Map<String, Timer> _debounceTimers = {};
  static const _debounce = Duration(seconds: 10);

  // ── Called from main queue (debounced) ───────────────────────────────────
  void scheduleUpdate(String dateFolder) {
    _debounceTimers[dateFolder]?.cancel();
    _debounceTimers[dateFolder] = Timer(_debounce, () {
      _buildAndUpload(dateFolder).catchError((dynamic e) {
        debugPrint('=== AttendanceAutoSync scheduleUpdate error: $e');
      });
    });
    debugPrint('=== AttendanceAutoSync: scheduled update for $dateFolder');
  }

  // ── Called directly from WorkManager (awaited, no timer) ─────────────────
  // WorkManager isolate closes after this returns — no dangling timers.
  Future<void> buildAndUploadNow(String dateFolder) =>
      _buildAndUpload(dateFolder);

  // ── Core: query Firestore → build Excel → upload to OneDrive ─────────────
  Future<void> _buildAndUpload(String dateFolder) async {
    debugPrint('=== AttendanceAutoSync: building Excel for $dateFolder');

    // ── 1. Query Firestore ───────────────────────────────────────────────────
    final sessions = <Map<String, dynamic>>[];
    try {
      // Try collectionGroup first — gets ALL users (admin view).
      // Requires Firestore rule:
      //   match /{path=**}/sessions/{doc} { allow read: if request.auth != null; }
      debugPrint('=== AttendanceAutoSync: querying collectionGroup for $dateFolder');
      try {
        final snap = await FirebaseFirestore.instance
            .collectionGroup('sessions')
            .where('dateFolder', isEqualTo: dateFolder)
            .get()
            .timeout(const Duration(seconds: 30));
        for (final doc in snap.docs) {
          sessions.add(doc.data());
        }
        debugPrint('=== AttendanceAutoSync: collectionGroup got ${sessions.length} sessions');
      } catch (cgErr) {
        // Fallback: current user only (if collectionGroup permission denied)
        debugPrint('=== AttendanceAutoSync: collectionGroup failed ($cgErr) — fallback to current user');
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid == null) {
          debugPrint('=== AttendanceAutoSync: no auth uid — cannot query');
          return;
        }
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('sessions')
            .where('dateFolder', isEqualTo: dateFolder)
            .get()
            .timeout(const Duration(seconds: 30));
        for (final doc in snap.docs) {
          sessions.add(doc.data());
        }
        debugPrint('=== AttendanceAutoSync: fallback got ${sessions.length} sessions');
      }
    } catch (e, st) {
      debugPrint('=== AttendanceAutoSync: Firestore FAILED: $e\n$st');
      return;
    }

    if (sessions.isEmpty) {
      debugPrint('=== AttendanceAutoSync: no sessions for $dateFolder — skip');
      return;
    }

    // Sort client-side: by userFolder then sessionStartMs
    sessions.sort((a, b) {
      final uCmp = (a['userFolder'] as String? ?? '')
          .compareTo(b['userFolder'] as String? ?? '');
      if (uCmp != 0) return uCmp;
      return ((a['sessionStartMs'] as int? ?? 0))
          .compareTo(b['sessionStartMs'] as int? ?? 0);
    });

    // ── 2. Build Excel workbook ──────────────────────────────────────────────
    final excel = Excel.createExcel();
    excel.delete('Sheet1');

    final sheetLabel = _dateLabel(dateFolder);
    final ws = excel[sheetLabel];
    _writeSheet(ws, dateFolder, sheetLabel, sessions);

    // ── 3. Save to temp file ─────────────────────────────────────────────────
    final bytes = excel.encode();
    if (bytes == null) {
      debugPrint('=== AttendanceAutoSync: Excel encode returned null — abort');
      return;
    }

    final tmp      = await getTemporaryDirectory();
    final fileName = 'OTN_Attendance_$dateFolder.xlsx';
    final filePath = '${tmp.path}/$fileName';
    await File(filePath).writeAsBytes(bytes);
    debugPrint('=== AttendanceAutoSync: saved temp → $filePath');

    // ── 4. Upload to OneDrive ────────────────────────────────────────────────
    try {
      debugPrint('=== AttendanceAutoSync: uploading $fileName → OTN Recorder/Attendance Reports/');
      await OneDriveService().uploadToAttendanceFolder(
        filePath:   filePath,
        fileName:   fileName,
        onProgress: (p) => debugPrint('=== AttendanceAutoSync: upload ${(p * 100).toInt()}%'),
        onStatus:   (s) => debugPrint('=== AttendanceAutoSync: $s'),
      );
      debugPrint('=== AttendanceAutoSync: ✓ SUCCESS — $fileName on OneDrive');
    } catch (e, st) {
      debugPrint('=== AttendanceAutoSync: OD upload FAILED: $e\n$st');
    } finally {
      try { File(filePath).deleteSync(); } catch (_) {}
    }
  }

  // ── Excel sheet builder ──────────────────────────────────────────────────
  void _writeSheet(Sheet ws, String dateFolder, String sheetLabel,
      List<Map<String, dynamic>> sessions) {
    // Row 0: Title
    _cell(ws, 0, 0,
        'OTN Video Recorder — Attendance  |  $sheetLabel',
        bg: _navy, fg: _green, bold: true, fontSize: 13, span: 8);

    // Row 1: Generated timestamp
    final now = DateFormat('dd MMM yyyy, HH:mm').format(DateTime.now());
    _cell(ws, 1, 0,
        'Generated: $now  (auto-updated on each upload)',
        bg: _subHdr, fg: _white, span: 8);

    // Row 2: Column headers
    const hdrs = ['#', 'Name', 'Session ID', 'Start Time',
                   'Duration', 'Chunks', 'Status', 'Notes'];
    for (var i = 0; i < hdrs.length; i++) {
      _cell(ws, 2, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }

    ws.setColumnWidth(0, 5);
    ws.setColumnWidth(1, 22);
    ws.setColumnWidth(2, 16);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 14);
    ws.setColumnWidth(5, 10);
    ws.setColumnWidth(6, 12);
    ws.setColumnWidth(7, 25);

    // Group sessions by user
    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final s in sessions) {
      final u = s['userFolder'] as String? ?? 'Unknown';
      byUser.putIfAbsent(u, () => []).add(s);
    }

    var rowIdx  = 3;
    var seqNum  = 1;
    var altUser = false;

    for (final entry in byUser.entries) {
      final userName     = entry.key;
      final userSessions = entry.value;
      final userBg       = altUser ? _userAlt : _userRow;
      altUser            = !altUser;

      for (var si = 0; si < userSessions.length; si++) {
        final s       = userSessions[si];
        final isFirst = si == 0;
        final secs    = s['totalSecs']      as int? ?? 0;
        final chunks  = s['chunksUploaded'] as int? ?? 0;
        final status  = s['status']         as String? ?? 'uploading';
        final startMs = s['sessionStartMs'] as int? ?? 0;
        final rawSid  = s['sessionId']      as String? ?? '';
        final sid     = rawSid.length >= 8
            ? rawSid.substring(0, 8).toUpperCase() : rawSid.toUpperCase();
        final startStr = startMs > 0
            ? DateFormat('HH:mm').format(
                DateTime.fromMillisecondsSinceEpoch(startMs))
            : '--';
        final statusLabel = status == 'synced' ? '✓ Complete' : '⏳ Uploading';
        final statusFg    = status == 'synced' ? _darkGrn : _orange;
        final notes       = status != 'synced' ? 'Upload in progress' : '';

        _cell(ws, rowIdx, 0, seqNum, bg: userBg);
        _cell(ws, rowIdx, 1, isFirst ? userName : '',
            bg: userBg, bold: isFirst, fg: isFirst ? _text : _grey);
        _cell(ws, rowIdx, 2, sid,        bg: userBg);
        _cell(ws, rowIdx, 3, startStr,   bg: userBg);
        _cell(ws, rowIdx, 4, _fmt(secs), bg: userBg);
        _cell(ws, rowIdx, 5, chunks,     bg: userBg);
        _cell(ws, rowIdx, 6, statusLabel,bg: userBg, fg: statusFg, bold: true);
        _cell(ws, rowIdx, 7, notes,      bg: userBg, fg: _grey);

        rowIdx++;
        seqNum++;
      }

      // User subtotal row
      final totalSecs   = userSessions.fold<int>(
          0, (s, d) => s + (d['totalSecs']      as int? ?? 0));
      final totalChunks = userSessions.fold<int>(
          0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
      _cell(ws, rowIdx, 0, '', bg: _totalBg);
      _cell(ws, rowIdx, 1,
          '$userName — ${userSessions.length} session${userSessions.length == 1 ? '' : 's'}',
          bg: _totalBg, fg: _totalFg, bold: true);
      _cell(ws, rowIdx, 2, '',              bg: _totalBg);
      _cell(ws, rowIdx, 3, '',              bg: _totalBg);
      _cell(ws, rowIdx, 4, _fmt(totalSecs), bg: _totalBg, fg: _totalFg, bold: true);
      _cell(ws, rowIdx, 5, totalChunks,     bg: _totalBg, fg: _totalFg, bold: true);
      _cell(ws, rowIdx, 6, '',              bg: _totalBg);
      _cell(ws, rowIdx, 7, '',              bg: _totalBg);
      rowIdx++;
    }

    // Grand total row
    final grandSecs   = sessions.fold<int>(
        0, (s, d) => s + (d['totalSecs']      as int? ?? 0));
    final grandChunks = sessions.fold<int>(
        0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
    rowIdx++; // blank gap
    _cell(ws, rowIdx, 0, 'TOTAL',
        bg: _green, fg: _white, bold: true, span: 2);
    _cell(ws, rowIdx, 1, '', bg: _green);
    _cell(ws, rowIdx, 2, '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
        bg: _green, fg: _white, bold: true);
    _cell(ws, rowIdx, 3, '',              bg: _green);
    _cell(ws, rowIdx, 4, _fmt(grandSecs), bg: _green, fg: _white, bold: true);
    _cell(ws, rowIdx, 5, grandChunks,     bg: _green, fg: _white, bold: true);
    _cell(ws, rowIdx, 6, '',              bg: _green);
    _cell(ws, rowIdx, 7, '',              bg: _green);
  }

  // ── Colors ────────────────────────────────────────────────────────────────
  static const _navy    = '#1A1A2E';
  static const _subHdr  = '#16213E';
  static const _hdrBg   = '#0F3460';
  static const _green   = '#00C853';
  static const _darkGrn = '#2E7D32';
  static const _orange  = '#E65100';
  static const _white   = '#FFFFFF';
  static const _text    = '#1A1A1A';
  static const _grey    = '#888888';
  static const _userRow = '#E8F5E9';
  static const _userAlt = '#F1F8E9';
  static const _totalBg = '#C8E6C9';
  static const _totalFg = '#1B5E20';
  static const _border  = '#C8E6C9';

  // ── Cell helper ───────────────────────────────────────────────────────────
  void _cell(Sheet ws, int row, int col, dynamic value, {
    String bg       = '#FFFFFF',
    String fg       = '#1A1A1A',
    bool   bold     = false,
    double fontSize = 10,
    int    span     = 1,
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
      fontSize:           fontSize.toInt(),
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
      ws.merge(idx,
          CellIndex.indexByColumnRow(
              columnIndex: col + span - 1, rowIndex: row));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _fmt(int secs) {
    if (secs <= 0) return '0m';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  String _dateLabel(String folder) {
    try {
      final p  = folder.split('-');
      final dt = DateTime(
          int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      return DateFormat('dd MMM yyyy').format(dt);
    } catch (_) {
      return folder;
    }
  }
}