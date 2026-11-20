"""Compare recorded-speech XCTest attachments with the fixed, independently labeled manifest."""
import argparse
import json
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path


def characters(text):
    folded = unicodedata.normalize("NFKC", text).casefold()
    return "".join(c for c in folded if unicodedata.category(c)[0] in ("L", "N"))


def distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


def date_decision(route, rows, expected):
    if route != expected["route"]:
        return False
    if route == "review":
        return True
    return len(rows) == 1 and rows[0].get("localDate") == expected.get("date")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("attachments", type=Path, nargs="+")
    args = parser.parse_args()
    clips = json.loads(args.manifest.read_text())
    observed = [row for path in args.attachments for row in json.loads(path.read_text())]
    keyed = {row["id"]: row for row in observed}
    if len(keyed) != len(observed) or set(keyed) != {c["id"] for c in clips}:
        raise ValueError("输入清单与回放结果不一一对应")
    summary = defaultdict(Counter)
    details = []
    for clip in clips:
        row = keyed[clip["id"]]
        if row["reference"] != clip["reference"]:
            raise ValueError("参考文本与测试快照不符")
        ref = characters(clip["reference"])
        actual = characters(row["transcript"])
        edits = distance(ref, actual)
        group = summary[clip["corpus"] + "/" + clip["condition"]]
        group.update(["samples", row["route"]])
        group["referenceCharacters"] += len(ref)
        group["edits"] += edits
        group["exact"] += int(actual == ref)
        row.update(characterEdits=edits, referenceCharacters=len(ref))
        if expected := clip.get("expected"):
            row["expected"] = expected
            row["dateDecisionCorrect"] = date_decision(row["route"], row["rows"], expected)
            ref_rows = row["parsedReference"]
            ref_direct = len(ref_rows) == 1 and bool(ref_rows[0]["title"].strip()) and not ref_rows[0].get("question")
            row["referenceDecisionCorrect"] = date_decision("saved" if ref_direct else "review", ref_rows, expected)
            row["actionKeywordPresent"] = any(
                expected["actionKeyword"] in r["title"] for r in row["rows"]
            )
            group["actionKeywordPresent"] += int(row["actionKeywordPresent"])
            if not row["dateDecisionCorrect"]:
                if row["route"] == "saved" and row["rows"][0].get("localDate"):
                    group["incorrectAutoDate"] += 1
                elif row["route"] == "review":
                    group["reviewInsteadOfDirect"] += 1
                elif row["route"] == "saved":
                    group["unexpectedUndatedSave"] += 1
            group["labeled"] += 1
            group["correctDecision"] += int(row["dateDecisionCorrect"])
            group["correctUsingReference"] += int(row["referenceDecisionCorrect"])
        details.append(row)
    for group in summary.values():
        group["CER"] = round(group["edits"] / group["referenceCharacters"], 6)
    args.output.write_text(json.dumps({"summary": summary, "clips": details}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
