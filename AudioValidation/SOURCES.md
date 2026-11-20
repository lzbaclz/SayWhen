# 真人录音测试素材

素材仅由专用测试目标 SayWhenAudioTests 读取。每条录音的语料编号、说话人编号、原始文本、来源路径、文件校验值都在 Fixtures/manifest.json。日常指令的期望分流、时间和动作关键词在首次回放前按参考文本标注。

## 日常指令

数据引用于 Magic Data Co., Ltd., “http://www.imagicdatatech.com/index.php/home/dataopensource/data_info/id/101”, 05/2019。使用 MAGICDATA Mandarin Chinese Read Speech Corpus 的 dev_set.tar.gz 原始 PCM WAV，逐字节提取，保留原编码，仅用于本机个人研究。原始录音置于 Fixtures/MagicData，已加入版本控制忽略清单。授权为 CC BY-NC-ND 4.0，同时附发行方 Usage Instruction。 [OpenSLR 68](https://www.openslr.org/68/) · [原档校验和](https://www.openslr.org/resources/68/checksum.md5)

参考原文使用[文本索引快照](https://huggingface.co/datasets/weege007/cosyvoice_magicdata-read/blob/c3d017a1a917d0f09d5be57df993b8da381664f3/dev/text)，所有 60 个录音编号和说话人编号另与发行方 dev.scp 和 SPKINFO 核对。

从原始开发集恢复相同样本可运行 `python3 scripts/restore_daily_speech.py /path/to/dev_set.tar.gz`。脚本检查原档 MD5 及每段 WAV 的 SHA-256。需要 Python 3.11 或更新版本。

## 交通声对照

人声来自北京希尔贝壳科技有限公司 AISHELL-1，采用 Apache License 2.0。引用 Hui Bu, Jiayu Du, Xingyu Na, Bengu Wu, Hao Zheng, “AIShell-1: An Open-Source Mandarin Speech Corpus and A Speech Recognition Baseline”, 2017。这里使用 S0061、S0076、S0083 的 12 条原录音，同一条语音各有原声及加噪版本。 [OpenSLR 33](https://www.openslr.org/33/) · [原始说话人归档快照](https://huggingface.co/datasets/AISHELL/AISHELL-1/tree/bbe295d530192a4cd41644b711c9aecd087df653/data_aishell/wav)

交通声来自 Joachim Thiemann、Nobutaka Ito、Emmanuel Vincent 的 DEMAND 1.0。使用 STRAFFIC_16k.zip 中的 STRAFFIC/ch01.wav，原档 MD5 为 2efa87262f272bbf9ba578088e81939c。按清单记录的起始采样位置截取等长噪声，以整段均方根将信噪比设为 +5 dB，叠加后仅在峰值可能削波时整体等比衰减，再量化为 16 位 PCM。以 traffic5dB 命名的派生混音按 CC BY-SA 3.0 提供，原始人声的署名与许可同时保留。 [DEMAND 原始录音与授权](https://zenodo.org/records/1227121) · [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/)
