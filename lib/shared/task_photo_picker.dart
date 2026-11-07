import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

typedef TaskPhotoPicker = Future<List<String>> Function(
  BuildContext context, {
  required int remaining,
});

final taskPhotoPickerProvider = Provider<TaskPhotoPicker>(
  (ref) =>
      (context, {required remaining}) =>
          showTaskPhotoPicker(context, remaining: remaining),
);

class TaskGalleryPhoto {
  const TaskGalleryPhoto({
    required this.id,
    required this.loadThumb,
    required this.loadPath,
  });
  final String id;
  final Future<Uint8List?> Function() loadThumb;
  final Future<String?> Function() loadPath;
}

class TaskGalleryPermissionException implements Exception {}

abstract class TaskPhotoGallerySource {
  Future<void> ensurePermission();
  Future<List<TaskGalleryPhoto>> fetchPage(int page, int size);
}

class DeviceTaskPhotoGallery implements TaskPhotoGallerySource {
  @override
  Future<void> ensurePermission() async {
    // 默认 common 同时检查图片和视频；本面板只读照片，不能因未授视频权限误拒。
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );
    if (!permission.isAuth && !permission.hasAccess) {
      throw TaskGalleryPermissionException();
    }
  }

  @override
  Future<List<TaskGalleryPhoto>> fetchPage(int page, int size) async {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (albums.isEmpty) return [];
    final assets = await albums.first.getAssetListPaged(page: page, size: size);
    return assets
        .map(
          (asset) => TaskGalleryPhoto(
            id: asset.id,
            loadThumb: () =>
                asset.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
            loadPath: () async =>
                (await asset.originFile ?? await asset.file)?.path,
          ),
        )
        .toList();
  }
}

abstract class TaskPhotoDevicePicker {
  Future<List<String>> pick({required bool camera, required int limit});
}

class SystemTaskPhotoPicker implements TaskPhotoDevicePicker {
  SystemTaskPhotoPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;
  @override
  Future<List<String>> pick({required bool camera, required int limit}) async {
    if (camera || limit <= 1) {
      final photo = await _picker.pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
      );
      return photo == null ? [] : [photo.path];
    }
    final photos = await _picker.pickMultiImage(limit: limit);
    return photos.map((photo) => photo.path).toList();
  }
}

/// Returns original paths. Preparing and copying into durable storage belongs
/// to the caller, so cancelling the sheet never changes a saved task.
Future<List<String>> showTaskPhotoPicker(
  BuildContext context, {
  required int remaining,
  TaskPhotoGallerySource? source,
  TaskPhotoDevicePicker? devicePicker,
}) async {
  if (remaining <= 0) return [];
  return await showModalBottomSheet<List<String>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _TaskPhotoSheet(
          remaining: remaining.clamp(1, 4),
          source: source ?? DeviceTaskPhotoGallery(),
          device: devicePicker ?? SystemTaskPhotoPicker(),
        ),
      ) ??
      [];
}

class _TaskPhotoSheet extends StatefulWidget {
  const _TaskPhotoSheet({
    required this.remaining,
    required this.source,
    required this.device,
  });
  final int remaining;
  final TaskPhotoGallerySource source;
  final TaskPhotoDevicePicker device;
  @override
  State<_TaskPhotoSheet> createState() => _TaskPhotoSheetState();
}

class _TaskPhotoSheetState extends State<_TaskPhotoSheet>
    with WidgetsBindingObserver {
  final _photos = <TaskGalleryPhoto>[];
  final _selected = <String>{};
  final _thumbs = <String, Future<Uint8List?>>{};
  final _scroll = ScrollController();
  String? _message;
  bool _denied = false;
  bool _loading = false;
  bool _busy = false;
  bool _more = true;
  int _page = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _denied) _reload();
  }

  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 300) _load();
  }

  Future<void> _reload() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _message = null;
      _denied = false;
    });
    try {
      await widget.source.ensurePermission();
      if (!mounted) return;
      _photos.clear();
      _thumbs.clear();
      _selected.clear();
      _page = 0;
      _more = true;
      _loading = false;
      await _load();
    } catch (error) {
      if (mounted) {
        setState(() {
          _denied = error is TaskGalleryPermissionException;
          _message = _denied ? '未授权访问相册，可使用上方相册入口选择照片' : '无法读取相册，请重试';
          _loading = false;
        });
      }
    }
  }

  Future<void> _load() async {
    if (_loading || !_more || _busy) return;
    setState(() => _loading = true);
    try {
      final photos = await widget.source.fetchPage(_page, 60);
      if (!mounted) return;
      setState(() {
        final ids = _photos.map((photo) => photo.id).toSet();
        _photos.addAll(photos.where((photo) => ids.add(photo.id)));
        _page++;
        _more = photos.length == 60;
        _message = _photos.isEmpty ? '相册中没有照片' : null;
      });
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取相册，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggle(String id) {
    if (_busy) return;
    setState(() {
      if (_selected.remove(id)) return;
      if (_selected.length >= widget.remaining) {
        _message = '最多还能添加 ${widget.remaining} 张照片';
      } else {
        _selected.add(id);
        _message = null;
      }
    });
  }

  Future<void> _pickSystem(bool camera) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final paths = await widget.device.pick(
        camera: camera,
        limit: widget.remaining,
      );
      if (!mounted) return;
      final unique = paths.toSet().toList();
      if (unique.length > widget.remaining) {
        setState(() => _message = '最多还能添加 ${widget.remaining} 张照片，请重新选择');
      } else if (unique.isNotEmpty) {
        Navigator.of(context).pop(unique);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = '无法打开${camera ? '相机' : '相册'}，请检查权限后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final paths = <String>[];
      for (final photo in _photos.where(
        (photo) => _selected.contains(photo.id),
      )) {
        final path = await photo.loadPath();
        if (path == null || path.isEmpty) throw StateError('missing photo');
        paths.add(path);
      }
      if (mounted) Navigator.of(context).pop(paths.toSet().toList());
    } catch (_) {
      if (mounted) setState(() => _message = '所选照片无法读取，请重选或重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.5,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _pickSystem(true),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('拍照'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _pickSystem(false),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('相册'),
                    ),
                  ],
                ),
              ),
              Text(
                '还可选择 ${widget.remaining - _selected.length} 张',
                key: const Key('task_photo_remaining'),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_message!, style: TextStyle(color: scheme.error)),
                ),
              if (_message != null && _photos.isEmpty)
                Wrap(
                  children: [
                    TextButton(
                      onPressed: _loading ? null : _reload,
                      child: const Text('重试'),
                    ),
                    if (_denied)
                      TextButton(
                        onPressed: PhotoManager.openSetting,
                        child: const Text('去设置'),
                      ),
                  ],
                ),
              Expanded(
                child: _photos.isEmpty && _loading
                    ? const Center(child: CircularProgressIndicator())
                    : GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 4,
                              crossAxisSpacing: 4,
                            ),
                        itemCount: _photos.length,
                        itemBuilder: (_, index) {
                          final photo = _photos[index];
                          final selected = _selected.contains(photo.id);
                          return Semantics(
                            selected: selected,
                            button: true,
                            label: '照片 ${index + 1}',
                            child: InkWell(
                              key: ValueKey('task_gallery_${photo.id}'),
                              onTap: _busy ? null : () => _toggle(photo.id),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  FutureBuilder<Uint8List?>(
                                    future: _thumbs.putIfAbsent(
                                      photo.id,
                                      photo.loadThumb,
                                    ),
                                    builder: (_, snapshot) =>
                                        snapshot.data == null
                                        ? ColoredBox(
                                            color:
                                                scheme.surfaceContainerHighest,
                                          )
                                        : Image.memory(
                                            snapshot.data!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, error, stack) =>
                                                const Icon(
                                                  Icons.broken_image_outlined,
                                                ),
                                          ),
                                  ),
                                  if (selected)
                                    ColoredBox(
                                      color: scheme.primary.withValues(
                                        alpha: .25,
                                      ),
                                    ),
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      color: selected
                                          ? scheme.primary
                                          : scheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _busy || _selected.isEmpty ? null : _confirm,
                  child: Text(_busy ? '正在读取照片…' : '添加所选（${_selected.length}）'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
