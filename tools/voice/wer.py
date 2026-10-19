#!/usr/bin/env python3
"""Word error rate of a dictated sentence against a fixed reference
(spec 2026-10-16 bt-headset-mic §11). Prints numbers only, never text."""
import argparse
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET


def words(text):
    text = unicodedata.normalize("NFC", text).lower()
    return re.sub(r"[^\w\s]", " ", text).split()


def edits(ref, hyp):
    """Minimal (cost, sub, del, ins) alignment."""
    rows = [[(j, 0, 0, j) for j in range(len(hyp) + 1)]]
    for i in range(1, len(ref) + 1):
        row = [(i, 0, i, 0)]
        for j in range(1, len(hyp) + 1):
            if ref[i - 1] == hyp[j - 1]:
                row.append(rows[i - 1][j - 1])
                continue
            c, s, d, n = rows[i - 1][j - 1]
            best = (c + 1, s + 1, d, n)
            c, s, d, n = rows[i - 1][j]
            best = min(best, (c + 1, s, d + 1, n))
            c, s, d, n = row[j - 1]
            best = min(best, (c + 1, s, d, n + 1))
            row.append(best)
        rows.append(row)
    return rows[-1][-1]


def score(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    cost, sub, dele, ins = edits(ref, hyp)
    return cost / max(len(ref), 1), len(ref), sub, dele, ins


def ui_text(path):
    """Text of the first EditText in a `uiautomator dump` file (the chat draft)."""
    for node in ET.parse(path).iter("node"):
        if node.get("class") == "android.widget.EditText":
            return node.get("text", "")
    sys.exit("no EditText in the dump")


def selftest():
    assert score("Eins, zwei, drei.", "eins zwei drei")[0] == 0.0
    wer, n, sub, dele, ins = score("eins zwei drei vier", "eins drei vier")
    assert (round(wer, 3), n, sub, dele, ins) == (0.25, 4, 0, 1, 0)
    wer, n, _, _, _ = score("der wind weht über das land", "der wind weht über land heute")
    assert (round(wer, 3), n) == (0.333, 6)
    assert words("Café Kopfhörer!") == ["café", "kopfhörer"]
    print("selftest ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--reference")
    parser.add_argument("--line", type=int, default=1)
    parser.add_argument("--hypothesis")
    parser.add_argument("--ui-dump")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    with open(args.reference, encoding="utf-8") as handle:
        reference = handle.read().splitlines()[args.line - 1]
    if args.ui_dump:
        hypothesis = ui_text(args.ui_dump)
    else:
        with open(args.hypothesis, encoding="utf-8") as handle:
            hypothesis = handle.read()
    wer, n, sub, dele, ins = score(reference, hypothesis)
    print(f"wer={wer:.3f} words={n} sub={sub} del={dele} ins={ins}")


if __name__ == "__main__":
    main()
