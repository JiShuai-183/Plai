import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/import_export/timetable_import_export.dart';
import '../../data/models/semester.dart';
import 'academic_html_parser.dart';
import 'timetable_providers.dart';

/// 导入方式选择。
enum _ImportChoice { overwriteCurrent, mergeCurrent, newSemester }

/// 课表文件导入导出交互。
///
/// - 导出：`file_picker` 选择保存位置写 JSON/CSV，并展示位置（可复制）；
/// - 导入：`file_picker` 选 JSON/CSV → 预览摘要 → 选择「覆盖/合并/新建学期」
///   后调用数据层 [TimetableImportExport] 严格校验写入（整体成功/失败）。
class ImportExportPage extends ConsumerWidget {
  const ImportExportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Semester?> semesterAsync =
        ref.watch(currentSemesterProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('课表导入导出')),
      body: semesterAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('加载失败')),
        data: (Semester? semester) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionTitle(context, '导出当前学期课表'),
              const SizedBox(height: 4),
              Text(
                semester == null ? '（当前无学期）' : '当前学期：${semester.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.data_object_outlined),
                      title: const Text('导出为 JSON 文件'),
                      subtitle: const Text('含学期、节次、课程信息'),
                      enabled: semester != null,
                      onTap: () => _export(context, ref, semester!, isJson: true),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.table_chart_outlined),
                      title: const Text('导出为 CSV 文件'),
                      subtitle: const Text('仅课程列表，不含节次'),
                      enabled: semester != null,
                      onTap: () => _export(context, ref, semester!, isJson: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _sectionTitle(context, '从文件导入课表'),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.file_open_outlined),
                  title: const Text('选择 JSON / CSV 文件导入'),
                  subtitle: const Text('先预览，再选择「覆盖 / 合并」'),
                  onTap: () => _import(context, ref),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);

  // ------------------------------------------------------------ 导出

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    Semester semester, {
    required bool isJson,
  }) async {
    final TimetableImportExport importer =
        ref.read(timetableImportExportProvider);
    final String ext = isJson ? 'json' : 'csv';
    final String fileName = 'plai_timetable_${semester.name}.$ext';

    final String content;
    try {
      content = isJson
          ? await importer.exportJson(semester.id!)
          : await importer.exportCsv(semester.id!);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出失败，请稍后重试')),
        );
      }
      return;
    }

    // 优先走系统保存对话框（file_picker 内部写字节）。
    Uri? saved;
    try {
      saved = await FilePicker.saveFile(
        dialogTitle: isJson ? '导出课表 JSON' : '导出课表 CSV',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(content)),
        type: FileType.custom,
        allowedExtensions: [ext],
      );
    } catch (_) {
      saved = null; // 平台不支持保存对话框时回退应用文档目录。
    }
    if (saved != null) {
      if (context.mounted) {
        await _showSavedPath(context, _uriLabel(saved));
      }
      return;
    }

    // 回退：写入应用文档目录。
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final String fallbackPath = p.join(dir.path, fileName);
      await File(fallbackPath).writeAsString(content, encoding: utf8);
      if (context.mounted) await _showSavedPath(context, fallbackPath);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出失败，请稍后重试')),
        );
      }
    }
  }

  String _uriLabel(Uri uri) =>
      uri.scheme == 'file' ? uri.toFilePath() : uri.toString();

  Future<void> _showSavedPath(BuildContext context, String path) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('导出成功'),
        content: Text(
          '已保存到：\n$path',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              Navigator.of(context).pop();
            },
            child: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 导入

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        dialogTitle: '选择课表文件',
        type: FileType.custom,
        allowedExtensions: ['json', 'csv', 'xls', 'html', 'htm'],
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件选择器不可用')),
        );
      }
      return;
    }
    if (file == null || !context.mounted) return;

    final String ext = (file.extension ?? '').toLowerCase();

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件读取失败')),
        );
      }
      return;
    }

    // 教务网页导出的 HTML 课表（.xls/.html/.htm 实为 HTML 表格）。
    if (ext == 'xls' || ext == 'html' || ext == 'htm') {
      // 内部各使用点均已 context.mounted 守卫。
      // ignore: use_build_context_synchronously
      await _importHtml(context, ref, bytes);
      return;
    }

    final bool isJson = ext == 'json';
    final String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件读取失败')),
        );
      }
      return;
    }

    final String preview = _preview(content, isJson);
    final Semester? semester = ref.read(currentSemesterProvider).valueOrNull;
    if (!isJson && semester == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV 不含学期信息，请先创建或切换到目标学期')),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final _ImportChoice? choice = await _askChoice(
      context,
      title: isJson ? '导入 JSON 课表' : '导入 CSV 课表',
      preview: preview,
      isNewSemesterAllowed: isJson,
    );
    if (choice == null || !context.mounted) return;

    final TimetableImportExport importer =
        ref.read(timetableImportExportProvider);
    final TimetableImportResult result;
    try {
      switch (choice) {
        case _ImportChoice.overwriteCurrent:
          result = isJson
              ? await importer.importJson(
                  content,
                  targetSemesterId: semester?.id,
                  strategy: ImportStrategy.overwrite,
                )
              : await importer.importCsv(
                  content,
                  // CSV 无学期信息，目标学期必为当前学期（上方已保证非空且必有主键）。
                  semesterId: semester!.id!,
                  strategy: ImportStrategy.overwrite,
                );
        case _ImportChoice.mergeCurrent:
          result = isJson
              ? await importer.importJson(
                  content,
                  targetSemesterId: semester?.id,
                  strategy: ImportStrategy.merge,
                )
              : await importer.importCsv(
                  content,
                  semesterId: semester!.id!,
                  strategy: ImportStrategy.merge,
                );
        case _ImportChoice.newSemester:
          result = await importer.importJson(
            content,
            targetSemesterId: null,
            strategy: ImportStrategy.merge,
          );
      }
    } on TimetableImportException catch (e) {
      if (context.mounted) _showImportErrors(context, e);
      return;
    }

    // _finishImport 内各 context 使用点均已 mounted 守卫。
    // ignore: use_build_context_synchronously
    await _finishImport(context, ref, result);
  }

  /// 导入完成收尾：切换学期、刷新数据、重排提醒、提示结果。
  Future<void> _finishImport(
    BuildContext context,
    WidgetRef ref,
    TimetableImportResult result,
  ) async {
    ref.read(currentSemesterIdProvider.notifier).state = result.semesterId;
    ref.invalidate(semestersProvider);
    ref.invalidate(coursesProvider);
    ref.invalidate(periodsProvider);
    ref.invalidate(holidaysProvider);
    try {
      await rescheduleTimetableReminders(ref);
    } catch (_) {
      // 重排失败不阻断导入完成提示。
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '导入完成：课程 ${result.coursesImported} 门，节次 ${result.periodsImported} 个',
          ),
        ),
      );
    }
  }

  /// 教务 HTML 字节解码：优先 UTF-8；失败回退 latin1（GBK/GB2312 不崩）。
  String _decodeHtml(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// 导入教务网页导出的 HTML 课表（解析 → 预览 → 覆盖/合并到当前学期）。
  Future<void> _importHtml(
    BuildContext context,
    WidgetRef ref,
    Uint8List bytes,
  ) async {
    final String html = _decodeHtml(bytes);

    final AcademicTimetableData data;
    try {
      data = parseAcademicTimetableHtml(html);
    } on FormatException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法识别的教务课表文件')),
        );
      }
      return;
    }

    final Semester? semester = ref.read(currentSemesterProvider).valueOrNull;
    if (semester == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先创建或切换到目标学期')),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final String preview =
        '学期：${data.semesterName}\n课程 ${data.courses.length} 门 · '
        '节次 ${data.periods.length} 节\n导入到当前学期「${semester.name}」';
    final _ImportChoice? choice = await _askChoice(
      context,
      title: '导入教务课表',
      preview: preview,
      isNewSemesterAllowed: false,
    );
    if (choice == null || !context.mounted) return;

    final String defaultColor = ref
            .read(timetableStatusSettingsProvider)
            .valueOrNull
            ?.defaultCourseColor ??
        '';
    final String semesterName =
        data.semesterName.isNotEmpty ? data.semesterName : semester.name;
    var totalWeeks = 20;
    for (final c in data.courses) {
      if (c.endWeek > totalWeeks) totalWeeks = c.endWeek;
    }
    final String content = jsonEncode(<String, Object?>{
      'semester': <String, Object?>{
        'name': semesterName,
        'startDate': '2026-09-01',
        'totalWeeks': totalWeeks,
      },
      'periods': data.periods.map((e) => e.toJson()).toList(),
      'courses': data.courses
          .map((e) => e.copyWith(color: defaultColor).toJson())
          .toList(),
    });

    final TimetableImportExport importer =
        ref.read(timetableImportExportProvider);
    final TimetableImportResult result;
    try {
      result = await importer.importJson(
        content,
        targetSemesterId: semester.id,
        strategy: choice == _ImportChoice.overwriteCurrent
            ? ImportStrategy.overwrite
            : ImportStrategy.merge,
      );
    } on TimetableImportException catch (e) {
      if (context.mounted) _showImportErrors(context, e);
      return;
    }
    // _finishImport 内各 context 使用点均已 mounted 守卫。
    // ignore: use_build_context_synchronously
    await _finishImport(context, ref, result);
  }

  /// 预览摘要（仅为信息展示，严格校验由数据层导入时执行）。
  String _preview(String content, bool isJson) {
    if (isJson) {
      try {
        final Object? decoded = jsonDecode(content);
        if (decoded is! Map) return 'JSON 根节点不是对象';
        final Object? sem = decoded['semester'];
        final String semName = sem is Map
            ? ((sem['name'] as Object?)?.toString() ?? '未知')
            : '未知';
        final int courses = decoded['courses'] is List
            ? (decoded['courses'] as List).length
            : 0;
        final int periods =
            decoded['periods'] is List ? (decoded['periods'] as List).length : 0;
        return '学期：$semName\n课程 $courses 门 · 节次 $periods 节';
      } catch (_) {
        return 'JSON 解析失败';
      }
    }
    final List<String> lines =
        content.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final int rows = lines.isEmpty ? 0 : lines.length - 1;
    return 'CSV 数据行：$rows 行';
  }

  Future<_ImportChoice?> _askChoice(
    BuildContext context, {
    required String title,
    required String preview,
    required bool isNewSemesterAllowed,
  }) {
    return showDialog<_ImportChoice>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        children: [
          Text(preview, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(_ImportChoice.overwriteCurrent),
            child: const Row(
              children: [
                Icon(Icons.playlist_remove),
                SizedBox(width: 12),
                Text('覆盖当前学期'),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(_ImportChoice.mergeCurrent),
            child: const Row(
              children: [
                Icon(Icons.merge),
                SizedBox(width: 12),
                Text('合并到当前学期'),
              ],
            ),
          ),
          if (isNewSemesterAllowed)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(context).pop(_ImportChoice.newSemester),
              child: const Row(
                children: [
                  Icon(Icons.add_box_outlined),
                  SizedBox(width: 12),
                  Text('新建学期（从文件信息）'),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _showImportErrors(BuildContext context, TimetableImportException e) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('导入失败'),
        content: SingleChildScrollView(
          child:
              Text(e.toString(), style: Theme.of(context).textTheme.bodySmall),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
