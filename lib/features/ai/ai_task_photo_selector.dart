import 'dart:io';

import 'package:flutter/material.dart';

import '../../shared/task_photo_viewer.dart';
import 'ai_task_photos.dart';

/// 候选照片只来自本次发送与任务已有附件，不打开额外选图入口。
class AiTaskPhotoSelector extends StatelessWidget {
  const AiTaskPhotoSelector({
    super.key,
    required this.draft,
    required this.cardIndex,
    required this.enabled,
    required this.onSelection,
  });

  final AiTaskPhotoDraft draft;
  final int cardIndex;
  final bool enabled;
  final Future<void> Function(List<String>) onSelection;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = draft.validationError;
    final options = draft.options;
    final allSelected =
        options.isNotEmpty &&
        options.every((option) => draft.selectedIds.contains(option.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '保存后的照片（${draft.selectedIds.length}/4）',
                style: TextStyle(
                  color: error == null ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
            ),
            if (options.isNotEmpty)
              TextButton(
                key: ValueKey('ai_photo_toggle_all_$cardIndex'),
                onPressed: enabled
                    ? () => onSelection(
                        allSelected
                            ? []
                            : [for (final option in options) option.id],
                      )
                    : null,
                child: Text(allSelected ? '取消全选' : '全选'),
              ),
          ],
        ),
        if (draft.selectedIds.isEmpty && !draft.needsSelection)
          Text('未附照片', style: TextStyle(color: scheme.onSurfaceVariant)),
        if (error != null) Text(error, style: TextStyle(color: scheme.error)),
        if (options.isNotEmpty) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in options)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(
                      children: [
                        GestureDetector(
                          key: ValueKey(
                            'ai_photo_view_${cardIndex}_${option.id}',
                          ),
                          onTap: enabled
                              ? () => showTaskPhotoViewer(
                                  context,
                                  paths: [for (final p in options) p.path],
                                  initialIndex: options.indexOf(option),
                                )
                              : null,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(option.path),
                              width: 68,
                              height: 68,
                              cacheWidth:
                                  (68 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => SizedBox(
                                width: 68,
                                height: 68,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: scheme.outline,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              key: ValueKey(
                                'ai_photo_select_${cardIndex}_${option.id}',
                              ),
                              value: draft.selectedIds.contains(option.id),
                              onChanged: enabled
                                  ? (checked) {
                                      final ids = [...draft.selectedIds];
                                      if (checked == true) {
                                        ids.add(option.id);
                                      } else {
                                        ids.remove(option.id);
                                      }
                                      onSelection(ids);
                                    }
                                  : null,
                            ),
                            Text(
                              option.label,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
