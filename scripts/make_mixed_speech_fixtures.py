"""Generate local-only Mandarin/English regression audio using macOS system voices."""
import json
import subprocess
import tempfile
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "AudioValidation" / "Fixtures" / "Mixed"
SAMPLES = [
    ("conference", "CVPR", [("zh", "今天早晨十点提醒我，我告诉同事"), ("en", "C V P R"), ("zh", "邮件的事情")]),
    ("zoom", "Zoom", [("zh", "明天上午九点提醒我打开"), ("en", "Zoom"), ("zh", "参加会议")]),
    ("github", "GitHub", [("zh", "周二下午两点提醒我更新"), ("en", "GitHub"), ("zh", "仓库")]),
    ("pdf", "PDF", [("zh", "明天把报告导出为"), ("en", "P D F")]),
    ("slides", "PPT", [("zh", "今天下午四点提醒我准备"), ("en", "P P T")]),
    ("research", "ICCV", [("zh", "记一下给同事发"), ("en", "I C C V"), ("zh", "会议议程")]),
]
OUT.mkdir(parents=True, exist_ok=True)
manifest = []
with tempfile.TemporaryDirectory() as temp:
    for name, term, pieces in SAMPLES:
        frames = []
        for lang, text in pieces:
            aiff = Path(temp) / "segment.aiff"
            subprocess.run(["say", "-v", "Tingting" if lang == "zh" else "Samantha",
                            "-r", "175", "-o", str(aiff), text], check=True)
            pcm = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(aiff), "-ar", "16000",
                                          "-ac", "1", "-af", "silenceremove=start_periods=1:start_threshold=-55dB,areverse,silenceremove=start_periods=1:start_threshold=-55dB,areverse", "-f", "s16le", "-"])
            frames.append(pcm)
        with wave.open(str(OUT / (name + ".wav")), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            out.writeframes((b"\0\0" * 1120).join(frames) + b"\0\0" * 1600)
        manifest.append({"file": name + ".wav", "term": term, "reference": "".join(s for _, s in pieces)})
(OUT / "index.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
