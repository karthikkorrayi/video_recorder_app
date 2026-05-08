import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:excel/excel.dart';
import 'onedrive_service.dart';

/// OTN Attendance Excel — three-sheet architecture:
///
///  Sheet "Raw Data"   — one row per chunk, append-only, never rebuilt
///  Sheet "DD MMM YYYY"— rebuilt per-date from Firestore (session summary)
///  Sheet "Overview"   — date × totals, upserted per date
///
/// The Raw sheet is the source-of-truth audit log.
/// Date sheets are generated summaries for admin use.
/// The app reads from Firestore — Excel is admin-only.
class AttendanceAutoSync {
  static final AttendanceAutoSync _i = AttendanceAutoSync._();
  factory AttendanceAutoSync() => _i;
  AttendanceAutoSync._();

  static const _odFolder   = 'OTN Recorder/Attendance Reports';
  static const _odFileName = 'OTN_Attendance.xlsx';
  static const _rawSheet   = 'Raw Data';

  final Map<String, Timer> _timers = {};
  static const _debounce = Duration(seconds: 10);

  void scheduleUpdate(String dateFolder) {
    _timers[dateFolder]?.cancel();
    _timers[dateFolder] = Timer(_debounce, () {
      buildAndUploadNow(dateFolder).catchError((dynamic e) {
        debugPrint('=== Attendance scheduleUpdate error: $e');
      });
    });
  }

  Future<void> buildAndUploadNow(String dateFolder) async {
    try {
      await _buildAndUpload(dateFolder);
    } catch (e, st) {
      debugPrint('=== Attendance: buildAndUploadNow error: $e\n$st');
    }
  }

  // ── Main build ────────────────────────────────────────────────────────────
  Future<void> _buildAndUpload(String dateFolder) async {
    debugPrint('=== Attendance: building for $dateFolder');

    final sessions = await _querySessions(dateFolder);
    debugPrint('=== Attendance: ${sessions.length} sessions found');

    final od    = OneDriveService();
    final bytes = await od.downloadFileBytes(
        folderPath: _odFolder, fileName: _odFileName);

    Excel excel;
    if (bytes != null) {
      try {
        excel = Excel.decodeBytes(bytes);
        if (excel.sheets.containsKey('Sheet1') && excel.sheets.length > 1) {
          excel.delete('Sheet1');
        }
        debugPrint('=== Attendance: loaded existing workbook '
            '(${excel.sheets.length} sheets)');
      } on Exception catch (e) {
        debugPrint('=== Attendance: decode Exception ($e) — new workbook');
        excel = Excel.createExcel(); excel.delete('Sheet1');
      } on Error catch (e) {
        debugPrint('=== Attendance: decode Error ($e) — new workbook');
        excel = Excel.createExcel(); excel.delete('Sheet1');
      }
    } else {
      excel = Excel.createExcel();
      excel.delete('Sheet1');
      debugPrint('=== Attendance: creating new workbook');
    }

    // 1. Raw Data sheet — append new chunk rows, never rebuild
    _appendRawRows(excel, sessions);

    // 2. Date sheet — rebuild today's date only
    if (sessions.isNotEmpty) {
      sessions.sort((a, b) {
        final u = (a['userFolder'] as String? ?? '')
            .compareTo(b['userFolder'] as String? ?? '');
        if (u != 0) return u;
        return ((a['sessionStartMs'] as int? ?? 0))
            .compareTo(b['sessionStartMs'] as int? ?? 0);
      });
      final sheetName = _sheetName(dateFolder);
      if (excel.sheets.containsKey(sheetName)) excel.delete(sheetName);
      _buildDateSheet(excel[sheetName], dateFolder, sheetName, sessions);

      // 3. Overview — upsert this date row
      if (!excel.sheets.containsKey('Overview')) {
        _buildOverviewHeader(excel['Overview']);
      }
      _upsertOverviewRow(excel['Overview'], dateFolder, sheetName, sessions);
    }

    // Encode + upload
    final encoded = excel.encode();
    if (encoded == null) {
      debugPrint('=== Attendance: encode returned null — abort');
      return;
    }
    final tmp      = await getTemporaryDirectory();
    final filePath = '${tmp.path}/$_odFileName';
    await File(filePath).writeAsBytes(encoded);
    try {
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

  // ── Raw Data sheet — append only ─────────────────────────────────────────
  void _appendRawRows(Excel excel, List<Map<String, dynamic>> sessions) {
    final ws = excel[_rawSheet];

    // Build header if sheet is new/empty
    final hasHeader = ws.maxRows > 0;
    if (!hasHeader) {
      _buildRawHeader(ws);
    }

    // Collect existing chunk keys to avoid duplicate rows
    // Key = "sessionId|partNumber"
    final existingKeys = <String>{};
    for (var r = 1; r < ws.maxRows; r++) {
      final sidCell  = ws.cell(CellIndex.indexByColumnRow(
          columnIndex: 2, rowIndex: r)).value;
      final partCell = ws.cell(CellIndex.indexByColumnRow(
          columnIndex: 4, rowIndex: r)).value;
      if (sidCell != null && partCell != null) {
        final sid  = sidCell  is TextCellValue ? sidCell.value.text  : sidCell.toString();
        final part = partCell is IntCellValue   ? partCell.value.toString()
                   : partCell is TextCellValue  ? partCell.value.text
                   : partCell.toString();
        existingKeys.add('$sid|$part');
      }
    }

    int rowNum = ws.maxRows; // append after last row
    int seqBase = rowNum;    // sequential row number offset

    for (final s in sessions) {
      final sessionId  = s['sessionId']      as String? ?? '';
      final userFolder = s['userFolder']     as String? ?? '';
      final dateFolder = s['dateFolder']     as String? ?? '';
      final startMs    = s['sessionStartMs'] as int?    ?? 0;
      final parts      = (s['parts'] as List?)?.cast<int>() ?? [];
      final totalSecs  = s['totalSecs']      as int?    ?? 0;
      final chunks     = s['chunksUploaded'] as int?    ?? 1;
      final sid6       = sessionId.length >= 6
          ? sessionId.substring(0, 6).toUpperCase() : sessionId;

      final startDt   = startMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(startMs) : null;

      // One row per chunk part
      final partList = parts.isNotEmpty
          ? parts : List.generate(chunks, (i) => i + 1);

      // Distribute totalSecs across chunks evenly if we don't have per-chunk data
      final perChunkSecs = chunks > 0 ? totalSecs ~/ chunks : 0;

      for (final partNum in partList) {
        final key = '$sid6|$partNum';
        if (existingKeys.contains(key)) continue; // already written

        // Estimate chunk start/end from session start + part offset
        final chunkStartSec = (partNum - 1) * perChunkSecs;
        final chunkEndSec   = partNum == partList.last
            ? totalSecs : partNum * perChunkSecs;
        final chunkSecs     = (chunkEndSec - chunkStartSec).clamp(0, 7200);

        final chunkStart = startDt != null
            ? startDt.add(Duration(seconds: chunkStartSec)) : null;
        final chunkEnd   = startDt != null
            ? startDt.add(Duration(seconds: chunkEndSec))   : null;

        final startStr  = chunkStart != null
            ? DateFormat('HH:mm:ss').format(chunkStart) : '--';
        final endStr    = chunkEnd   != null
            ? DateFormat('HH:mm:ss').format(chunkEnd)   : '--';
        final dateStr   = startDt    != null
            ? DateFormat('dd-MM-yyyy').format(startDt)  : dateFolder;
        final chunkName = 'Part ${partNum.toString().padLeft(2,'0')}';

        final isAlt = (rowNum - 1) % 2 == 0;
        final bg    = isAlt ? _rowAlt : _rowMain;

        _c(ws, rowNum, 0,  seqBase + rowNum - (hasHeader ? 0 : 1), bg: bg);
        _c(ws, rowNum, 1,  dateStr,    bg: bg);
        _c(ws, rowNum, 2,  userFolder, bg: bg, bold: false);
        _c(ws, rowNum, 3,  sid6,       bg: bg);
        _c(ws, rowNum, 4,  chunkName,  bg: bg);
        _c(ws, rowNum, 5,  startStr,   bg: bg);
        _c(ws, rowNum, 6,  endStr,     bg: bg);
        _c(ws, rowNum, 7,  _fmt(chunkSecs), bg: bg, bold: true);

        existingKeys.add(key);
        rowNum++;
      }
    }

    debugPrint('=== Attendance: Raw sheet now has $rowNum rows');
  }

  void _buildRawHeader(Sheet ws) {
    _c(ws, 0, 0, 'OTN — RAW CHUNK LOG',
        bg: _navy, fg: _green, bold: true, sz: 12, span: 8);
    const hdrs = ['#', 'Date', 'User', 'Session ID',
                   'Chunk', 'Start Time', 'End Time', 'Duration'];
    for (var i = 0; i < hdrs.length; i++) {
      _c(ws, 1, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }
    ws.setColumnWidth(0, 6);
    ws.setColumnWidth(1, 14);
    ws.setColumnWidth(2, 24);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 10);
    ws.setColumnWidth(5, 12);
    ws.setColumnWidth(6, 12);
    ws.setColumnWidth(7, 14);
  }

  // ── Date sheet (session-level summary) ───────────────────────────────────
  void _buildDateSheet(Sheet ws, String dateFolder, String sheetName,
      List<Map<String, dynamic>> sessions) {
    final generated = DateFormat('dd MMM yyyy, HH:mm').format(DateTime.now());

    _c(ws, 0, 0, 'OTN VIDEO RECORDER — ATTENDANCE REPORT',
        bg: _navy, fg: _green, bold: true, sz: 13, span: 8);
    _c(ws, 1, 0, '$sheetName   |   Generated: $generated',
        bg: _subHdr, fg: _white, sz: 10, span: 8);
    const hdrs = ['#', 'User Name', 'Session ID', 'Date',
                   'Start Time', 'End Session', 'Duration', 'Chunks'];
    for (var i = 0; i < hdrs.length; i++) {
      _c(ws, 2, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }
    ws.setColumnWidth(0, 5);
    ws.setColumnWidth(1, 24);
    ws.setColumnWidth(2, 14);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 14);
    ws.setColumnWidth(5, 14);
    ws.setColumnWidth(6, 16);
    ws.setColumnWidth(7, 10);

    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final s in sessions) {
      final u = s['userFolder'] as String? ?? 'Unknown';
      byUser.putIfAbsent(u, () => []).add(s);
    }

    var row = 3; var seqNum = 1; var altBg = false;

    for (final entry in byUser.entries) {
      final name  = entry.key;
      final rows  = entry.value;
      final rowBg = altBg ? _rowAlt : _rowMain;
      altBg = !altBg;

      for (var si = 0; si < rows.length; si++) {
        final s       = rows[si];
        final secs    = s['totalSecs']      as int? ?? 0;
        final chunks  = s['chunksUploaded'] as int? ?? 0;
        final startMs = s['sessionStartMs'] as int? ?? 0;
        final rawId   = s['sessionId']      as String? ?? '';
        final sid     = rawId.length >= 6
            ? rawId.substring(0, 6).toUpperCase() : rawId.toUpperCase();

        final startDt  = startMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(startMs) : null;
        final endDt    = startDt != null
            ? startDt.add(Duration(seconds: secs)) : null;
        final startStr = startDt != null
            ? DateFormat('HH:mm:ss').format(startDt) : '--';
        final endStr   = endDt   != null
            ? DateFormat('HH:mm:ss').format(endDt)   : '--';
        final dateStr  = startDt != null
            ? DateFormat('dd-MM-yyyy').format(startDt) : dateFolder;

        _c(ws, row, 0, seqNum,                bg: rowBg);
        _c(ws, row, 1, si == 0 ? name : '',   bg: rowBg,
            fg: si == 0 ? _text : _grey, bold: si == 0);
        _c(ws, row, 2, sid,                   bg: rowBg);
        _c(ws, row, 3, dateStr,               bg: rowBg);
        _c(ws, row, 4, startStr,              bg: rowBg);
        _c(ws, row, 5, endStr,                bg: rowBg);
        _c(ws, row, 6, _fmt(secs),            bg: rowBg, bold: true);
        _c(ws, row, 7, chunks,                bg: rowBg);
        row++; seqNum++;
      }

      // User subtotal row
      final subSecs   = rows.fold<int>(
          0, (s, d) => s + (d['totalSecs'] as int? ?? 0));
      final subChunks = rows.fold<int>(
          0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
      for (var c = 0; c < 8; c++) _c(ws, row, c, '', bg: _subtotalBg);
      _c(ws, row, 1,
          '$name  (${rows.length} session${rows.length == 1 ? '' : 's'})',
          bg: _subtotalBg, fg: _subtotalFg, bold: true);
      _c(ws, row, 6, _fmt(subSecs),  bg: _subtotalBg, fg: _subtotalFg, bold: true);
      _c(ws, row, 7, subChunks,      bg: _subtotalBg, fg: _subtotalFg, bold: true);
      row++;
    }

    // Grand total
    row++;
    final grandSecs   = sessions.fold<int>(
        0, (s, d) => s + (d['totalSecs'] as int? ?? 0));
    final grandChunks = sessions.fold<int>(
        0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
    final userCount   = byUser.keys.length;
    for (var c = 0; c < 8; c++) _c(ws, row, c, '', bg: _green);
    _c(ws, row, 0, 'TOTAL', bg: _green, fg: _white, bold: true);
    _c(ws, row, 2, '${sessions.length} sessions',
        bg: _green, fg: _white, bold: true);
    _c(ws, row, 3, '$userCount users', bg: _green, fg: _white, bold: true);
    _c(ws, row, 6, _fmt(grandSecs),  bg: _green, fg: _white, bold: true, sz: 11);
    _c(ws, row, 7, grandChunks,      bg: _green, fg: _white, bold: true);
  }

  // ── Overview sheet ────────────────────────────────────────────────────────
  void _buildOverviewHeader(Sheet ws) {
    _c(ws, 0, 0, 'OTN RECORDER — ALL DATES OVERVIEW',
        bg: _navy, fg: _green, bold: true, sz: 13, span: 5);
    _c(ws, 1, 0,
        'Auto-updated on every session upload. Open date sheets for details.',
        bg: _subHdr, fg: _white, span: 5);
    const hdrs = ['Date', 'Sessions', 'Total Duration', 'Total Chunks', 'Users'];
    for (var i = 0; i < hdrs.length; i++) {
      _c(ws, 2, i, hdrs[i], bg: _hdrBg, fg: _white, bold: true);
    }
    ws.setColumnWidth(0, 16); ws.setColumnWidth(1, 12);
    ws.setColumnWidth(2, 18); ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 40);
  }

  void _upsertOverviewRow(Sheet ws, String dateFolder, String sheetName,
      List<Map<String, dynamic>> sessions) {
    int? existingRow;
    for (var r = 3; r < ws.maxRows; r++) {
      final cell = ws.cell(
          CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
      final val  = cell.value;
      if (val is TextCellValue && val.value.text == dateFolder) {
        existingRow = r; break;
      }
    }
    final row        = existingRow ?? ws.maxRows;
    final isAlt      = (row - 3) % 2 == 0;
    final bg         = isAlt ? _rowMain : _rowAlt;
    final grandSecs  = sessions.fold<int>(
        0, (s, d) => s + (d['totalSecs'] as int? ?? 0));
    final grandChunks = sessions.fold<int>(
        0, (s, d) => s + (d['chunksUploaded'] as int? ?? 0));
    final users = sessions
        .map((d) => d['userFolder'] as String? ?? '')
        .toSet().join(', ');

    _c(ws, row, 0, dateFolder,       bg: bg);
    _c(ws, row, 1, sessions.length,  bg: bg);
    _c(ws, row, 2, _fmt(grandSecs),  bg: bg, bold: true);
    _c(ws, row, 3, grandChunks,      bg: bg);
    _c(ws, row, 4, users,            bg: bg);
  }

  // ── Firestore query ───────────────────────────────────────────────────────
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
    }
    return sessions;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
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
  static const _white      = '#FFFFFF';
  static const _text       = '#1A1A1A';
  static const _grey       = '#888888';
  static const _rowMain    = '#E8F5E9';
  static const _rowAlt     = '#F1F8E9';
  static const _subtotalBg = '#C8E6C9';
  static const _subtotalFg = '#1B5E20';
  static const _border     = '#C8E6C9';

  // ── Cell builder ──────────────────────────────────────────────────────────
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