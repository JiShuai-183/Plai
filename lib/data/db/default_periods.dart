import '../models/period.dart';

/// 内置国内高校常用节次模板（PRD-课表模块 §2.4 默认模板）。
///
/// 数据层只提供模板常量，不自动写入库；由上层在首次启动/设置页
/// 检测节次表为空时调用插入。各校可自定义。
const List<Period> defaultPeriods = [
  Period(index: 1, startTime: '08:00', endTime: '08:45'),
  Period(index: 2, startTime: '08:55', endTime: '09:40'),
  Period(index: 3, startTime: '10:00', endTime: '10:45'),
  Period(index: 4, startTime: '10:55', endTime: '11:40'),
  Period(index: 5, startTime: '14:00', endTime: '14:45'),
  Period(index: 6, startTime: '14:55', endTime: '15:40'),
  Period(index: 7, startTime: '16:00', endTime: '16:45'),
  Period(index: 8, startTime: '16:55', endTime: '17:40'),
  Period(index: 9, startTime: '19:00', endTime: '19:45'),
  Period(index: 10, startTime: '19:55', endTime: '20:40'),
  Period(index: 11, startTime: '20:50', endTime: '21:35'),
  Period(index: 12, startTime: '21:45', endTime: '22:30'),
];
