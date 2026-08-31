import 'package:flutter/material.dart';

/// 全局导航 key。
///
/// 通知点击深链（冷启动拉起 / 运行中点击）需要在不持有 context 的情况下
/// 拿到 [NavigatorState]，故在 [MaterialApp] 上挂此 key（见 `lib/main.dart`），
/// 本模块通过它统一分发页面跳转。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
