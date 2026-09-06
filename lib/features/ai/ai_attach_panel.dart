import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

/// S9 增强：「+」面板——功能排（相机/相册/文件/敬请期待）+ 设备相册照片网格。
///
/// - 网格数据经 [AiGallerySource] 抽象（生产实现 [PhotoManagerGallerySource]），
///   3 列缩略图、分页加载；点按多选，底部「添加所选（n）」一次性回调原图路径；
/// - 相册无权限 / 无照片 / 数据源异常各有独立容错态。

/// 面板初始加载与每次分页的照片数。
const int _pageSize = 60;

/// 相册权限未授权（[detail] 为数据源返回的原始状态，供诊断显示）。
class AiGalleryPermissionException implements Exception {
  const AiGalleryPermissionException([this.detail = '']);

  final String detail;

  @override
  String toString() => detail;
}

/// 相册里的一张照片（缩略图与原图路径均为惰性加载）。
class AiGalleryPhoto {
  const AiGalleryPhoto({
    required this.id,
    required this.loadThumb,
    required this.loadOriginPath,
  });

  /// 稳定标识（多选去重）。
  final String id;

  /// 缩略图字节（供网格渲染）。
  final Future<Uint8List?> Function() loadThumb;

  /// 原图本地路径（识别用；不可得返回 null）。
  final Future<String?> Function() loadOriginPath;
}

/// 相册数据源抽象（面板只依赖本接口，便于测试注入）。
abstract class AiGallerySource {
  const AiGallerySource();

  /// 校验权限；未授权抛 [AiGalleryPermissionException]。
  Future<void> ensurePermission();

  /// 分页拉取照片（[page] 从 0 起）；返回条数 < [size] 表示没有更多。
  Future<List<AiGalleryPhoto>> fetchPage(int page, int size);
}

/// 生产实现：photo_manager 读设备相册。
class PhotoManagerGallerySource implements AiGallerySource {
  const PhotoManagerGallerySource();

  @override
  Future<void> ensurePermission() async {
    final PermissionState p = await PhotoManager.requestPermissionExtend();
    if (p.isAuth || p.hasAccess) return;
    // 个别 ROM 上「部分访问」等状态的枚举映射可能偏保守 → 实证兜底：
    // 真能读到相册就视为有权限；读不到才按未授权（携带原始状态供诊断）。
    try {
      await fetchPage(0, 1);
      return;
    } on AiGalleryPermissionException {
      rethrow;
    } catch (_) {
      throw AiGalleryPermissionException('状态: ${p.name}');
    }
  }

  @override
  Future<List<AiGalleryPhoto>> fetchPage(int page, int size) async {
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
    );
    if (paths.isEmpty) return const <AiGalleryPhoto>[];
    final List<AssetEntity> assets =
        await paths.first.getAssetListPaged(page: page, size: size);
    return <AiGalleryPhoto>[
      for (final AssetEntity a in assets)
        AiGalleryPhoto(
          id: a.id,
          loadThumb: () =>
              a.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
          loadOriginPath: () async =>
              (await a.originFile ?? await a.file)?.path,
        ),
    ];
  }
}

/// 相册数据源 Provider（测试可 override 注入假源）。
final aiGallerySourceProvider = Provider<AiGallerySource>(
  (ref) => const PhotoManagerGallerySource(),
);

/// 弹出「+」面板。
///
/// [onCamera]：相机卡（面板收起后触发）；[onGalleryPicker]：相册卡（收起后
/// 打开系统相册选择器）；[onAttachPhotos]：网格多选确认（收起后带原图路径）。
/// [source]：相册数据源（默认 photo_manager 实现；测试可注入假源）。
Future<void> showAiAttachSheet(
  BuildContext context, {
  required VoidCallback onCamera,
  required VoidCallback onGalleryPicker,
  required ValueChanged<List<String>> onAttachPhotos,
  AiGallerySource? source,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) {
      void close() => Navigator.of(sheetContext).pop();
      return _AttachPanel(
        source: source ?? const PhotoManagerGallerySource(),
        onCamera: () {
          close();
          onCamera();
        },
        onGalleryPicker: () {
          close();
          onGalleryPicker();
        },
        onAttachPhotos: (List<String> paths) {
          close();
          onAttachPhotos(paths);
        },
      );
    },
  );
}

enum _GalleryState { loading, ready, denied, empty, error }

class _AttachPanel extends StatefulWidget {
  const _AttachPanel({
    required this.source,
    required this.onCamera,
    required this.onGalleryPicker,
    required this.onAttachPhotos,
  });

  final AiGallerySource source;
  final VoidCallback onCamera;
  final VoidCallback onGalleryPicker;
  final ValueChanged<List<String>> onAttachPhotos;

  @override
  State<_AttachPanel> createState() => _AttachPanelState();
}

class _AttachPanelState extends State<_AttachPanel>
    with WidgetsBindingObserver {
  _GalleryState _state = _GalleryState.loading;
  final List<AiGalleryPhoto> _photos = <AiGalleryPhoto>[];
  final Map<String, Future<Uint8List?>> _thumbFutures =
      <String, Future<Uint8List?>>{};
  final Set<String> _selectedIds = <String>{};
  final ScrollController _gridCtl = ScrollController();

  /// 未授权时的诊断信息（数据源返回的原始权限状态）。
  String _deniedDetail = '';

  int _page = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gridCtl.addListener(_onGridScroll);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从系统设置授权回来（面板停在未授权态时）自动重新拉取。
    if (state == AppLifecycleState.resumed &&
        _state == _GalleryState.denied) {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gridCtl.removeListener(_onGridScroll);
    _gridCtl.dispose();
    super.dispose();
  }

  void _onGridScroll() {
    if (!_hasMore ||
        _loadingMore ||
        !_gridCtl.hasClients ||
        _gridCtl.position.extentAfter > 400) {
      return;
    }
    _loadMore();
  }

  /// 权限校验 → 首页照片。
  Future<void> _bootstrap() async {
    setState(() => _state = _GalleryState.loading);
    try {
      await widget.source.ensurePermission();
      _page = 0;
      _photos.clear();
      _hasMore = true;
      await _loadMore();
      if (mounted && _state != _GalleryState.ready) {
        setState(
            () => _state = _photos.isEmpty ? _GalleryState.empty : _GalleryState.ready);
      }
    } on AiGalleryPermissionException catch (e) {
      if (mounted) {
        setState(() {
          _deniedDetail = e.detail;
          _state = _GalleryState.denied;
        });
      }
    } catch (_) {
      // 数据源异常（含宿主 widget 测试无平台通道）→ 容错态。
      if (mounted) setState(() => _state = _GalleryState.error);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final List<AiGalleryPhoto> list =
          await widget.source.fetchPage(_page, _pageSize);
      if (mounted) {
        setState(() {
          _photos.addAll(list);
          _page++;
          _hasMore = list.length >= _pageSize;
          if (_state != _GalleryState.ready) {
            _state =
                _photos.isEmpty ? _GalleryState.empty : _GalleryState.ready;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _state = _GalleryState.error);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _resolveAndConfirm() async {
    final List<String> paths = <String>[];
    for (final AiGalleryPhoto photo in _photos) {
      if (!_selectedIds.contains(photo.id)) continue;
      final String? path = await photo.loadOriginPath();
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    if (paths.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选照片不可用，请重选')),
      );
      return;
    }
    widget.onAttachPhotos(paths);
  }

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double height = MediaQuery.of(context).size.height * 0.72;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 拖动把手。
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 功能排。
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: <Widget>[
                _FuncCard(
                  icon: Icons.photo_camera_outlined,
                  label: '相机',
                  onTap: widget.onCamera,
                ),
                _FuncCard(
                  icon: Icons.photo_outlined,
                  label: '相册',
                  onTap: widget.onGalleryPicker,
                ),
                _FuncCard(
                  icon: Icons.insert_drive_file_outlined,
                  label: '文件',
                  onTap: () {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('发送文件将在后续版本开放')),
                    );
                  },
                ),
                _FuncCard(
                  icon: Icons.auto_awesome_outlined,
                  label: '敬请期待',
                  enabled: false,
                  onTap: () {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('该功能即将开放')),
                    );
                  },
                ),
              ].map((Widget w) => Expanded(child: w)).toList(),
            ),
          ),
          const Divider(height: 1),
          // 相册网格区。
          Expanded(child: _buildGalleryArea(theme)),
          // 多选确认条。
          if (_selectedIds.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                    top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
              ),
              child: Row(
                children: [
                  Text('已选 ${_selectedIds.length} 张',
                      style: theme.textTheme.bodyMedium),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _resolveAndConfirm,
                    icon: const Icon(Icons.document_scanner_outlined,
                        size: 18),
                    label: Text('添加所选（${_selectedIds.length}）'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGalleryArea(ThemeData theme) {
    switch (_state) {
      case _GalleryState.loading:
        return const Center(child: CircularProgressIndicator());
      case _GalleryState.denied:
        return _GalleryHint(
          icon: Icons.lock_outline,
          text: '未授权访问相册',
          subtitle: _deniedDetail.isEmpty ? null : _deniedDetail,
          action: FilledButton.tonal(
            onPressed: PhotoManager.openSetting,
            child: const Text('去设置'),
          ),
        );
      case _GalleryState.error:
        return _GalleryHint(
          icon: Icons.error_outline,
          text: '无法读取相册',
          action: FilledButton.tonal(
            onPressed: _bootstrap,
            child: const Text('重试'),
          ),
        );
      case _GalleryState.empty:
        return const _GalleryHint(
          icon: Icons.photo_library_outlined,
          text: '相册中没有照片',
        );
      case _GalleryState.ready:
        final int itemCount = _photos.length + (_hasMore ? 3 : 0); // 尾部占位
        return GridView.builder(
          controller: _gridCtl,
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          itemCount: itemCount,
          itemBuilder: (BuildContext context, int index) {
            if (index >= _photos.length) {
              return const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final AiGalleryPhoto photo = _photos[index];
            final bool selected = _selectedIds.contains(photo.id);
            final Future<Uint8List?> thumbFuture = _thumbFutures.putIfAbsent(
              photo.id,
              photo.loadThumb,
            );
            return GestureDetector(
              key: ValueKey<String>('ai_gallery_photo_${photo.id}'),
              onTap: () => _toggle(photo.id),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: FutureBuilder<Uint8List?>(
                      future: thumbFuture,
                      builder:
                          (BuildContext ctx, AsyncSnapshot<Uint8List?> snap) {
                        final Uint8List? data = snap.data;
                        if (data == null) {
                          return Container(
                              color:
                                  theme.colorScheme.surfaceContainerHighest);
                        }
                        return Image(
                          image: MemoryImage(data),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        );
                      },
                    ),
                  ),
                  if (selected)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.check,
                            size: 15, color: theme.colorScheme.onPrimary),
                      ),
                    ),
                ],
              ),
            );
          },
        );
    }
  }
}

/// 功能卡（参考图样式：圆角浅底 + 图标 + 文字）。
class _FuncCard extends StatelessWidget {
  const _FuncCard({
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = enabled ? scheme.onSurface : scheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 0.92,
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 30, color: fg),
                const SizedBox(height: 8),
                Text(label,
                    style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 网格区状态提示。
class _GalleryHint extends StatelessWidget {
  const _GalleryHint({
    required this.icon,
    required this.text,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String text;

  /// 附加诊断小字（可空）。
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 10),
          Text(text,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                subtitle!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          if (action != null) ...<Widget>[
            const SizedBox(height: 12),
            action!,
          ],
        ],
      ),
    );
  }
}
