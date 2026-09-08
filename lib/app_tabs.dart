import 'package:flutter/foundation.dart';

/// App 底部导航当前选中 Tab 的索引广播（0=课表，1=今日，2=AI）。
///
/// [AppShell] 在切 tab 时写入；各 Tab 页面可监听「自己被选中」做进入动作
/// （如今日页在每次被切入时把日期条「今天」回中）。
final ValueNotifier<int> appTabIndex = ValueNotifier<int>(0);
