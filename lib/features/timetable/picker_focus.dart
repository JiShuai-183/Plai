import 'package:flutter/material.dart';

/// 打开选择器前先清焦点，防「选完时间/日期后软键盘再次弹出」。
///
/// 反直觉的坑（勿当冗余删除）：本模块时间/日期字段挂在 [ListTile] 的 onTap
/// （开时间拨盘 / 日期选择器），**不是** TextField —— 点它们不会转移焦点，
/// 同一对话框里的文本输入框（节次序号 / 学期名称）若持有焦点，就全程仍是
/// primaryFocus。选择器走 showDialog 路由，弹窗期间底路由的 FocusScope 仍把
/// 那个输入框记为 focusedChild；弹窗关闭、焦点回到原路由时它重新取得
/// primary focus → TextInputConnection 重连 → 键盘再次弹出。
/// 打开前清一次即让底路由的 focusedChild 置空、弹出后无从恢复（实测单次即够，
/// 无需 await 后再清）。
///
/// 与 `../schedule/task_form_page.dart` 的 `_withPicker` 同一套做法；集中在本模块
/// 一处，避免该注释在两个页面复制后各自漂移。
Future<T?> withPickerFocus<T>(Future<T?> Function() open) {
  FocusManager.instance.primaryFocus?.unfocus();
  return open();
}
