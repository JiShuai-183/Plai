import 'package:flutter/material.dart';

import '../../routes/app_routes.dart';

/// AI 页：底部导航第 3 位 Tab。
///
/// 本页仅结构与导航骨架，真实对话 / 历史 / 配置功能后续（S5）实现：
/// - AppBar leading：三条杠菜单（历史对话入口，S5 实现，现轻提示）；
/// - AppBar title：暂显「AI」（S5 起改当前会话标题）；
/// - AppBar actions：齿轮 → push 打开设置页（原 Tab 设置入口迁入此处）；
/// - body：居中占位，外层可滚动兜底。
class AiPage extends StatelessWidget {
  const AiPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: '历史对话',
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('历史对话功能即将上线')),
          ),
        ),
        title: const Text('AI'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.settings),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'AI 功能准备中',
                    style: TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
