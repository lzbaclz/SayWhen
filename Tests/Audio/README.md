# 本机语音夹具

默认源码不包含录音。在 macOS 上运行以下命令可为本机模拟器测试生成示例，测试期望识别出「下周三下午三点去复诊」。

```sh
say -v Tingting -o /tmp/saywhen-sample.aiff '下周三下午三点去复诊'
afconvert -f WAVE -d LEI16@16000 /tmp/saywhen-sample.aiff Tests/Audio/mandarin.wav
```

录音只供本机测试，缺少夹具时对应测试会跳过。
