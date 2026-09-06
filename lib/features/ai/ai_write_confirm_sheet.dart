import 'package:flutter/material.dart';

/// 待确认的写操作条目（页面侧已把参数转成人类可读描述）。
class AiWriteConfirmItem {
  const AiWriteConfirmItem({required this.name, required this.description});

  /// 工具名（内部标识）。
  final String name;

  /// 一句话描述（卡片文案，如「新建待办任务「交作业」· 9月8日」）。
  final String description;
}

/// 弹出写操作逐条确认面板（模态，不可点外部/下拉关闭）。
///
/// 返回与 [items] 等长的「是否执行」列表：每条可独立勾选（默认勾选），
/// 点「执行选中项」按勾选结果返回；点「全部跳过」返回全 false。
Future<List<bool>> showAiWriteConfirmSheet(
  BuildContext context, {
  required List<AiWriteConfirmItem> items,
}) async {
  final List<bool> selected = List<bool>.filled(items.length, true);
  final List<bool>? result = await showModalBottomSheet<List<bool>>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext ctx, void Function(VoidCallback) setSheetState) {
          final ThemeData theme = Theme.of(ctx);
          int selectedCount = selected.where((bool v) => v).length;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline,
                            size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('AI 请求修改数据',
                              style: theme.textTheme.titleMedium),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '以下操作需要你确认后才会真正执行；取消勾选的将被跳过。',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (BuildContext ctx, int index) {
                        return CheckboxListTile(
                          value: selected[index],
                          onChanged: (bool? v) => setSheetState(
                              () => selected[index] = v ?? false),
                          secondary: const Icon(Icons.edit_note_outlined),
                          title: Text(
                            items[index].description,
                            style: theme.textTheme.bodyMedium,
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext)
                              .pop(List<bool>.filled(items.length, false)),
                          child: const Text('全部跳过'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selectedCount == 0
                              ? null
                              : () => Navigator.of(sheetContext)
                                  .pop(List<bool>.of(selected)),
                          child: Text('执行选中项（$selectedCount）'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  return result ?? List<bool>.filled(items.length, false);
}
