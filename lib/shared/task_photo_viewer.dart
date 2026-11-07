import 'dart:io';

import 'package:flutter/material.dart';

Future<void> showTaskPhotoViewer(
  BuildContext context, {
  required List<String> paths,
  int initialIndex = 0,
}) async {
  if (paths.isEmpty) return;
  await showDialog<void>(
    context: context,
    useSafeArea: true,
    builder: (_) => _PhotoViewer(
      paths: List.unmodifiable(paths),
      initialIndex: initialIndex.clamp(0, paths.length - 1),
    ),
  );
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.paths, required this.initialIndex});
  final List<String> paths;
  final int initialIndex;
  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages;
  late int _index;
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: SafeArea(
      child: Column(
        children: [
          Row(
            children: [
              const CloseButton(),
              Expanded(
                child: Text(
                  '${_index + 1} / ${widget.paths.length}',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: widget.paths.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (_, index) => InteractiveViewer(
                key: ValueKey('task_photo_zoom_$index'),
                minScale: 1,
                maxScale: 6,
                child: Center(
                  child: Image.file(
                    File(widget.paths[index]),
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, stack) => const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined),
                        SizedBox(height: 8),
                        Text('照片无法加载'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
