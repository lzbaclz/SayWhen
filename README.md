# 说到 · SayWhen

一款原生 iPhone 语音待办 App。按住说话，松手记下；时间不明确时可以补选钟点，也可以直接保存全天事项。

- 使用 SwiftUI 与 SwiftData 在本机保存标题、备注和提醒。
- 普通话和英语使用 Apple Speech 在设备上转写。中英混说时支持常用英文缩写，也可在设置中加入人名和项目名。无法使用麦克风时支持键入。
- 用 UserNotifications 安排本地提醒，主动确认后才通过 EventKit 写入所选日历。
- 默认在到期前一天晚上 20:00 提醒，可在左上角设置中改为提前若干小时或分钟。每条待办可在详情中单独调整，明确说出的提醒时刻优先。
- 支持从保存回执改字、完成与撤销，以及手动核对日历修改。

## 运行

用 Xcode 26.3 或兼容版本打开 `SayWhen.xcodeproj`，选择 `SayWhen` scheme 和 iPhone 模拟器运行，最低部署版本为 iOS 18。真机安装请在 Xcode 的 Signing & Capabilities 选择自己的开发团队和可用的 Bundle ID。工程源配置为 `project.yml`，修改项目结构后可运行 `xcodegen generate`。

常规测试在 `Tests/` 和 `UITests/`。真人音频回放使用单独的 `SayWhen-RecordedSpeech` scheme；请按 `AudioValidation/SOURCES.md` 准备真人语料。运行 `python3 scripts/make_mixed_speech_fixtures.py` 可在本机生成六段中英混读测试音频。

[技术支持](https://lzbaclz.github.io/SayWhen/support.html) · [隐私政策](https://lzbaclz.github.io/SayWhen/privacy.html)

## 许可

项目源码采用 [MIT 许可证](LICENSE)。第三方测试语料及相应授权文件各自遵循原许可。
