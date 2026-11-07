import 'dart:convert';

import '../../data/models/task.dart';
import '../schedule/schedule_providers.dart';
import 'ai_tool_context.dart';

/// 仅由 App 构造并持久化；模型提交的同名字段在准备提案时一律丢弃。
const aiTaskPhotoDraftKey = '_task_photos';

class AiTaskPhotoOption {
  const AiTaskPhotoOption({
    required this.id,
    required this.path,
    required this.isExisting,
    required this.index,
  });
  final String id;
  final String path;
  final bool isExisting;

  /// 本地集合内的零起始序号，展示给用户时加一。
  final int index;
  String get label => '${isExisting ? '原照片' : '本次图片'} ${index + 1}';
}

class AiTaskPhotoDraft {
  AiTaskPhotoDraft._(
    this.requestId,
    this.sourcePaths,
    this.basePaths,
    this.selectedIds,
    this.needsSelection, [
    this._error,
  ]);
  final String? requestId;
  final List<String> sourcePaths;
  final List<String> basePaths;
  final List<String> selectedIds;
  final bool needsSelection;
  final String? _error;

  static AiTaskPhotoDraft? fromArgs(Map<String, dynamic> args) {
    if (!args.containsKey(aiTaskPhotoDraftKey)) return null;
    try {
      final raw = Map<String, dynamic>.from(args[aiTaskPhotoDraftKey] as Map);
      if (raw['version'] != 1 ||
          (raw['requestId'] != null && raw['requestId'] is! String) ||
          raw['needsSelection'] is! bool) {
        throw const FormatException('照片草稿格式错误');
      }
      final source = _paths(raw['sourcePaths']);
      final base = _paths(raw['basePaths']);
      final selected = List<String>.from(raw['selected'] as List);
      return AiTaskPhotoDraft._(
        raw['requestId'] as String?,
        source,
        base,
        List.unmodifiable(selected),
        raw['needsSelection'] as bool,
      );
    } catch (_) {
      return AiTaskPhotoDraft._(
        null,
        const [],
        const [],
        const [],
        false,
        '照片草稿损坏，请重新确认',
      );
    }
  }

  List<AiTaskPhotoOption> get options => List.unmodifiable([
    for (var i = 0; i < basePaths.length; i++)
      AiTaskPhotoOption(
        id: 'old:$i',
        path: basePaths[i],
        isExisting: true,
        index: i,
      ),
    for (var i = 0; i < sourcePaths.length; i++)
      AiTaskPhotoOption(
        id: 'new:$i',
        path: sourcePaths[i],
        isExisting: false,
        index: i,
      ),
  ]);

  String? get validationError {
    if (_error != null) return _error;
    final available = options.map((o) => o.id).toSet();
    if (selectedIds.toSet().length != selectedIds.length ||
        selectedIds.any((id) => !available.contains(id))) {
      return '照片选择无效，请重新选择';
    }
    if (needsSelection) return '请选择本项日程的照片，或明确选择不附照片';
    if (selectedIds.length > 4) return '最多保留4张照片，请移除多余照片';
    return null;
  }

  String get summary {
    final old = selectedIds.where((id) => id.startsWith('old:')).length;
    final added = selectedIds.where((id) => id.startsWith('new:')).length;
    if (needsSelection) return '照片待选择';
    if (basePaths.isEmpty) return '附加 $added 张照片';
    return '照片：保留 $old 张，新增 $added 张，移除 ${basePaths.length - old} 张';
  }

  Map<String, dynamic> _toJson() => {
    'version': 1,
    'requestId': requestId,
    'sourcePaths': sourcePaths,
    'basePaths': basePaths,
    'selected': selectedIds,
    'needsSelection': needsSelection,
  };

  Map<String, dynamic> withSelection(
    Map<String, dynamic> originalArgs,
    Iterable<String> selected,
  ) {
    if (_error != null) throw const FormatException('照片草稿损坏');
    final ids = selected.toList();
    final valid = options.map((o) => o.id).toSet();
    if (ids.toSet().length != ids.length ||
        ids.any((id) => !valid.contains(id))) {
      throw const FormatException('照片选择无效');
    }
    final canonical = [
      for (final option in options)
        if (ids.contains(option.id)) option.id,
    ];
    final next = AiTaskPhotoDraft._(
      requestId,
      sourcePaths,
      basePaths,
      List.unmodifiable(canonical),
      false,
    );
    final args = _copy(originalArgs);
    args[aiTaskPhotoDraftKey] = next._toJson();
    // 同步公开序号供文字描述/意图去重；真正执行仍验证完整内部快照。
    args['photo_indices'] = [
      for (final option in options)
        if (!option.isExisting && canonical.contains(option.id))
          option.index + 1,
    ];
    args['remove_photo_indices'] = [
      for (final option in options)
        if (option.isExisting && !canonical.contains(option.id))
          option.index + 1,
    ];
    final kept = canonical.where((id) => id.startsWith('old:')).length;
    final added = canonical.length - kept;
    args['photo_mode'] = canonical.isEmpty
        ? 'clear'
        : kept == basePaths.length
        ? (added == 0 ? 'keep' : 'append')
        : added == 0
        ? 'remove'
        : kept == 0
        ? 'replace'
        : 'append';
    return args;
  }
}

Future<Map<String, dynamic>> prepareTaskPhotoArgs(
  AiToolContext context,
  Map<String, dynamic> input, {
  int createCount = 1,
}) async {
  final args = _copy(input)..remove(aiTaskPhotoDraftKey);
  final action = args['action'];
  if (action != 'create' && action != 'update') return args;
  final validation = validateTaskPhotoArgs(args);
  if (validation != null) throw FormatException(validation);
  final source = _paths(context.imagePaths);
  if (source.isNotEmpty && context.requestId == null) {
    throw const FormatException('照片缺少本次发送绑定');
  }
  Task? existing;
  if (action == 'update') {
    final id = args['task_id'];
    if (id is! int) throw const FormatException('缺少有效task_id');
    existing = await context.read(taskRepositoryProvider).getTaskById(id);
    if (existing == null) throw const FormatException('任务不存在或已删除');
  }
  final base = _paths(existing?.imagePaths ?? const <String>[]);
  final hasPhotos = _hasPublicFields(args);
  if (source.isEmpty && base.isEmpty && !hasPhotos) return args;
  final newIndices = _indices(args['photo_indices'], source.length);
  final removed = _indices(args['remove_photo_indices'], base.length);
  final mode =
      args['photo_mode'] as String? ??
      (args.containsKey('photo_indices')
          ? 'append'
          : args.containsKey('remove_photo_indices')
          ? 'remove'
          : 'keep');
  final chosen = <String>[];
  var needs = false;
  if (action == 'create') {
    if (removed.isNotEmpty) throw const FormatException('新建日程没有可移除的原照片');
    if (mode == 'clear') {
      // 显式不附图。
    } else if (args.containsKey('photo_indices')) {
      chosen.addAll(newIndices.map((i) => 'new:$i'));
    } else if (source.isNotEmpty && createCount > 1) {
      needs = true;
    } else {
      chosen.addAll(List.generate(source.length, (i) => 'new:$i'));
    }
  } else {
    if (mode == 'keep' && (newIndices.isNotEmpty || removed.isNotEmpty)) {
      throw const FormatException('保留照片与照片增删参数冲突');
    }
    if (mode == 'remove' && newIndices.isNotEmpty) {
      throw const FormatException('移除模式不能同时新增照片');
    }
    if (mode == 'clear' && (newIndices.isNotEmpty || removed.isNotEmpty)) {
      throw const FormatException('清空模式不能同时指定照片');
    }
    if (mode != 'replace' && mode != 'clear') {
      chosen.addAll([
        for (var i = 0; i < base.length; i++)
          if (!removed.contains(i)) 'old:$i',
      ]);
    }
    if (mode == 'append' || mode == 'replace') {
      final additions = args.containsKey('photo_indices')
          ? newIndices
          : List.generate(source.length, (i) => i);
      chosen.addAll(additions.map((i) => 'new:$i'));
    }
  }
  args[aiTaskPhotoDraftKey] = AiTaskPhotoDraft._(
    context.requestId,
    source,
    base,
    List.unmodifiable(chosen),
    needs,
  )._toJson();
  return args;
}

String? validateTaskPhotoArgs(Map<String, dynamic> args) {
  final mode = args['photo_mode'];
  if (args.containsKey('photo_mode') &&
      !const ['keep', 'append', 'replace', 'remove', 'clear'].contains(mode)) {
    return 'photo_mode仅支持keep/append/replace/remove/clear';
  }
  for (final key in ['photo_indices', 'remove_photo_indices']) {
    if (!args.containsKey(key)) continue;
    if (args[key] is! List) return '$key需为整数数组';
    try {
      _indices(args[key], 4);
    } catch (_) {
      return '$key需为1到4之间的不重复整数数组';
    }
  }
  return AiTaskPhotoDraft.fromArgs(args)?.validationError;
}

bool hasTaskPhotoChanges(Map<String, dynamic> args) {
  final draft = AiTaskPhotoDraft.fromArgs(args);
  if (draft == null) return _hasPublicFields(args);
  final old = List.generate(draft.basePaths.length, (i) => 'old:$i');
  return draft.validationError != null || !_same(draft.selectedIds, old);
}

Object? taskPhotoChangeSignature(Map<String, dynamic> args) {
  final draft = AiTaskPhotoDraft.fromArgs(args);
  if (draft != null) return draft._toJson();
  return {
    for (final key in ['photo_mode', 'photo_indices', 'remove_photo_indices'])
      if (args.containsKey(key)) key: args[key],
  };
}

class AiTaskPhotoFiles {
  AiTaskPhotoFiles(Iterable<String> paths, Iterable<String> created)
    : imagePaths = List.unmodifiable(paths),
      createdPaths = List.unmodifiable(created);
  final List<String> imagePaths;
  final List<String> createdPaths;
}

Future<AiTaskPhotoFiles> materializeTaskPhotos(
  AiToolContext context,
  Map<String, dynamic> args, {
  Task? existing,
}) async {
  final draft = AiTaskPhotoDraft.fromArgs(args);
  if (draft == null) {
    if (_hasPublicFields(args) ||
        (args['action'] == 'create' && context.imagePaths.isNotEmpty)) {
      throw const FormatException('请先确认照片选择');
    }
    return AiTaskPhotoFiles(existing?.imagePaths ?? const [], const []);
  }
  final error = draft.validationError;
  if (error != null) throw FormatException(error);
  if (draft.requestId != context.requestId ||
      !_same(draft.sourcePaths, context.imagePaths)) {
    throw const FormatException('照片不属于本次发送，请重新确认');
  }
  final base = existing?.imagePaths ?? const <String>[];
  if (!_same(draft.basePaths, base)) {
    throw const FormatException('任务照片已变化，请重新确认');
  }
  final created = <String>[];
  final result = <String>[];
  try {
    for (final id in draft.selectedIds) {
      final option = draft.options.singleWhere((o) => o.id == id);
      if (option.isExisting) {
        result.add(base[option.index]);
      } else {
        final path = await context
            .read(taskImageStoreProvider)
            .importFile(context.imagePaths[option.index]);
        created.add(path);
        result.add(path);
      }
    }
    return AiTaskPhotoFiles(result, created);
  } catch (_) {
    await releaseTaskPhotoCopies(context, created);
    rethrow;
  }
}

Future<void> releaseTaskPhotoCopies(
  AiToolContext context,
  Iterable<String> paths,
) async {
  if (paths.isEmpty) return;
  try {
    await context.read(taskPhotoReleaseProvider)(paths);
  } catch (_) {
    // 回收失败保守留文件，不能把已成功的写入误报成失败。
  }
}

bool _hasPublicFields(Map<String, dynamic> args) => [
  'photo_mode',
  'photo_indices',
  'remove_photo_indices',
].any(args.containsKey);

List<int> _indices(Object? raw, int count) {
  if (raw == null) return const [];
  if (raw is! List ||
      raw.length > 4 ||
      raw.any((v) => v is! int || v < 1 || v > count)) {
    throw const FormatException('照片序号超出可选范围');
  }
  final values = raw.cast<int>();
  if (values.toSet().length != values.length) {
    throw const FormatException('照片序号重复');
  }
  return values.map((v) => v - 1).toList(growable: false);
}

List<String> _paths(Object? raw) {
  if (raw is! List ||
      raw.length > 4 ||
      raw.any((p) => p is! String || p.isEmpty)) {
    throw const FormatException('照片来源列表无效');
  }
  return List<String>.unmodifiable(raw);
}

bool _same(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);
Map<String, dynamic> _copy(Map<String, dynamic> args) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(args)) as Map);
