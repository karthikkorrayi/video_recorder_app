import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:excel/excel.dart';
import 'onedrive_service.dart';

/// Auto-updating attendance Excel on OneDrive.
///
/// Flow (triggered after every session upload completes):
///   1. Download existing OTN_Attendance.xlsx from OneDrive (if present)
///   2. Load it → find or create sheet for that date
///   3. Upsert the user's session row (by sessionId — idempotent)
///   4. Re-upload to same OneDrive path (overwrites)
///
/// Admin opens:  OTN Recorder/Attendance Reports/OTN_Attendance.xlsx
/// No export button. No user action needed. Fully automatic.
class AttendanceExportService {
  static final AttendanceExportService _i = AttendanceExportService._();
  factory AttendanceExportService() => _i;
  AttendanceExportService._();

  static const _odFolder   = 'OTN Recorder/Attendance Reports';
  static const _odFileName = 'OTN_Attendance.xlsx';

  // excel package uses '#RRGGBB' for ExcelColor
  static const _navy    = '#1A1A2E';
  static const _green   = '#00C853';
  static const _ltGreen = '#E8F5E9';
  static const _altRow  = '#F1F8E9';
  static const _darkGrn = '#2E7D32';
  static const _orange  = '#E65100';
  static const _subHdr  = '#16213E';
  static const _white   = '#FFFFFF';
  static const _border  = '#C8E6C9';

  // ── Called after every session upload completes ───────────────────────────
  /// Updates the OneDrive attendance Excel for one session.
  /// Safe to call multiple times — upserts by sessionId (idempotent).
  Future<void> updateForSession({
    required String sessionId,
    required String dateFolder,   // DD-MM-YYYY
    required String userFolder,   // display name
    required int    totalSecs,
    required int    chunksUploaded,
    required int    sessionStartMs,
    String          status = 'Complete',
  }) async {
    try {
      debugPrint('=== Attendance: updating OD Excel for $dateFolder / $userFolder');

      // 1. Download existing file bytes (null = file doesn't exist yet)
      final od    = OneDriveService();
      final bytes = await od.downloadFileBytes(
          folderPath: _odFolder, fileName: _odFileName);

      // 2. Load or create workbook
      final excel = bytes != null
          ? Excel.decodeBytes(bytes)
          : Excel.createExcel();

      // Remove default Sheet1 on first creation
      if (bytes == null && excel.sheets.containsKey('Sheet1')) {
        excel.delete('Sheet1');
      }

      // 3. Ensure Overview sheet exists
      _ensureOverviewSheet(excel);

      // 4. Find or create date sheet
      final sheetName = _sheetName(dateFolder);
      _ensureDateSheet(excel, sheetName, dateFolder);
      final ws = excel[sheetName];

      // 5. Upsert this session row
      _upsertSessionRow(
        ws:             ws,
        sessionId:      sessionId,
        userFolder:     userFolder,
        dateFolder:     dateFolder,
        totalSecs:      totalSecs,
        chunksUploaded: chunksUploaded,
        sessionStartMs: sessionStartMs,
        status:         status,
      );

      // 6. Refresh overview row for this date
      _refreshOverviewRow(excel, dateFolder, sheetName);

      // 7. Encode and upload back to OneDrive
      final encoded = excel.encode();
      if (encoded == null) throw Exception('Excel encode failed');

      final tmpDir  = await getTemporaryDirectory();
      final tmpFile = File('${tmpDir.path}/$_odFileName');
      await tmpFile.writeAsBytes(encoded);

      await od.uploadToAttendanceFolder(
        filePath:   tmpFile.path,
        fileName:   _odFileName,
        onProgress: (_) {},
        onStatus:   (_) {},
      );

      await tmpFile.delete().catchError((e) => tmpFile);
      debugPrint('=== Attendance: OD Excel updated ✓');
    } catch (e) {
      // Non-fatal — attendance update failure must never block video upload
      debugPrint('=== Attendance: update error (non-fatal): $e');
    }
  }

  // ── Sheet name from DD-MM-YYYY → "03 May 2026" ───────────────────────────
  String _sheetName(String folder) {
    try {
      final p  = folder.split('-');
      final dt = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      return DateFormat('dd MMM yyyy').format(dt);
    } catch (_) {
      return folder;   
    }
  }

  // ── Duration formatter ────────────────────────────────────────────────────
  String _fmt(int secs) {
    if (secs <= 0) return '0m';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  // ── Ensure Overview sheet ─────────────────────────────────────────────────
  void _ensureOverviewSheet(Excel excel) {
    if (excel.sheets.containsKey('Overview')) return;
    final ws = excel['Overview'];

    // Title
    _hdr(ws, 0, 0, 'OTN Recorder — Attendance Overview (Auto-Updated)', colSpan: 5);

    // Column headers
    final hdrs = ['Date', 'Sessions', 'Total Chunks', 'Total Duration', 'Participants'];
    for (var i = 0; i < hdrs.length; i++) {
      _subHdrCell(ws, 1, i, hdrs[i]);
    }
    ws.setColumnWidth(0, 16);
    ws.setColumnWidth(1, 14);
    ws.setColumnWidth(2, 16);
    ws.setColumnWidth(3, 18);
    ws.setColumnWidth(4, 40);
  }

  // ── Ensure date sheet with header ─────────────────────────────────────────
  void _ensureDateSheet(Excel excel, String sheetName, String dateFolder) {
    final ws = excel[sheetName];
    // Check if header already exists
    if (ws.maxRows > 0) return;

    // Title row
    _hdr(ws, 0, 0, 'OTN Recorder — $dateFolder  |  Auto-Updated', colSpan: 8);

    // Column headers
    final hdrs = ['#', 'Name', 'Session ID', 'Start Time',
                  'Duration', 'Chunks', 'Status', 'Last Updated'];
    for (var i = 0; i < hdrs.length; i++) {
      _subHdrCell(ws, 1, i, hdrs[i]);
    }
    ws.setColumnWidth(0, 5);
    ws.setColumnWidth(1, 22);
    ws.setColumnWidth(2, 16);
    ws.setColumnWidth(3, 14);
    ws.setColumnWidth(4, 14);
    ws.setColumnWidth(5, 12);
    ws.setColumnWidth(6, 12);
    ws.setColumnWidth(7, 20);
  }

  // ── Upsert session row (idempotent by sessionId) ──────────────────────────
  void _upsertSessionRow(
      {required Sheet  ws,
       required String sessionId,
       required String userFolder,
       required String dateFolder,
       required int    totalSecs,
       required int    chunksUploaded,
       required int    sessionStartMs,
       required String status}) {
    // Find existing row with this sessionId (col 2 = Session ID)
    int? existingRow;
    for (var r = 2; r < ws.maxRows; r++) {
      final cell = ws.cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: r));
      final val  = cell.value;
      if (val is TextCellValue && (val.value.text ?? '') == sessionId.substring(0, 8).toUpperCase()) {
        existingRow = r;
        break;
      }
    }

    final row     = existingRow ?? ws.maxRows;
    final isAlt   = (row - 2) % 2 == 0;
    final bg      = isAlt ? _ltGreen : _altRow;
    final rowNum  = row - 1; // 1-based display number

    final startDt = sessionStartMs > 0
        ? DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(sessionStartMs))
        : '--';
    final sid8    = sessionId.length >= 8
        ? sessionId.substring(0, 8).toUpperCase() : sessionId.toUpperCase();
    final now     = DateFormat('dd MMM HH:mm').format(DateTime.now());

    _dataCell(ws, row, 0, rowNum,          bg: bg);
    _dataCell(ws, row, 1, userFolder,      bg: bg, align: HorizontalAlign.Left);
    _dataCell(ws, row, 2, sid8,            bg: bg);
    _dataCell(ws, row, 3, startDt,         bg: bg);
    _dataCell(ws, row, 4, _fmt(totalSecs), bg: bg);
    _dataCell(ws, row, 5, chunksUploaded,  bg: bg);
    _dataCell(ws, row, 6, status,          bg: bg,
        fontColor: status == 'Complete' ? _darkGrn : _orange, bold: true);
    _dataCell(ws, row, 7, now,             bg: bg);
  }

  // ── Refresh overview row for this date ───────────────────────────────────
  void _refreshOverviewRow(Excel excel, String dateFolder, String sheetName) {
    final ov = excel['Overview'];
    if (ov.maxRows < 2) return;

    final ws = excel[sheetName];

    // Count sessions, chunks, duration, participants from date sheet
    var sessions  = 0;
    var chunks    = 0;
    final names   = <String>{};

    for (var r = 2; r < ws.maxRows; r++) {
      final nameCell = ws.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
      final val = nameCell.value;
      if (val is TextCellValue && (val.value.text?.isNotEmpty ?? false)) {
        sessions++;
        names.add(val.value.text ?? '');

        final chunksCell = ws.cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: r));
        final cv = chunksCell.value;
        if (cv is IntCellValue) chunks += cv.value;
      }
    }

    // Find or create overview row for this date
    int? ovRow;
    for (var r = 2; r < ov.maxRows; r++) {
      final cell = ov.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
      final val  = cell.value;
      if (val is TextCellValue && (val.value.text ?? '') == dateFolder) {
        ovRow = r; break;
      }
    }
    ovRow ??= ov.maxRows;

    final isAlt = (ovRow - 2) % 2 == 0;
    final bg    = isAlt ? _ltGreen : _altRow;

    _dataCell(ov, ovRow, 0, dateFolder,          bg: bg);
    _dataCell(ov, ovRow, 1, sessions,            bg: bg);
    _dataCell(ov, ovRow, 2, chunks,              bg: bg);
    _dataCell(ov, ovRow, 3, '—',                 bg: bg); // duration updated via secs col
    _dataCell(ov, ovRow, 4, names.join(', '),    bg: bg, align: HorizontalAlign.Left);
  }

  // ── Cell helpers ──────────────────────────────────────────────────────────
  CellStyle _style({
    String bg          = _white,
    String fontColor   = '#111111',
    bool   bold        = false,
    double fontSize    = 10,
    HorizontalAlign align = HorizontalAlign.Center,
  }) => CellStyle(
    backgroundColorHex: ExcelColor.fromHexString(bg),
    fontColorHex:       ExcelColor.fromHexString(fontColor),
    bold:               bold,
    fontSize:           fontSize.toInt(),
    horizontalAlign:    align,
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

  void _hdr(Sheet ws, int row, int col, String text,
      {int colSpan = 1}) {
    final idx  = CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);
    final cell = ws.cell(idx);
    cell.value     = TextCellValue(text);
    cell.cellStyle = _style(
        bg: _navy, fontColor: _green, bold: true, fontSize: 12);
    if (colSpan > 1) {
      ws.merge(idx,
          CellIndex.indexByColumnRow(columnIndex: col + colSpan - 1, rowIndex: row));
    }
  }

  void _subHdrCell(Sheet ws, int row, int col, String text) {
    final cell = ws.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    cell.value     = TextCellValue(text);
    cell.cellStyle = _style(bg: _subHdr, fontColor: _white, bold: true);
  }

  void _dataCell(Sheet ws, int row, int col, dynamic value,
      {String bg            = _white,
       String fontColor     = '#111111',
       bool   bold          = false,
       HorizontalAlign align = HorizontalAlign.Center}) {
    final cell = ws.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
    if (value is int) {
      cell.value = IntCellValue(value);
    } else if (value is double) {
      cell.value = DoubleCellValue(value);
    } else {
      cell.value = TextCellValue(value.toString());
    }
    cell.cellStyle = _style(bg: bg, fontColor: fontColor, bold: bold, align: align);
  }
}