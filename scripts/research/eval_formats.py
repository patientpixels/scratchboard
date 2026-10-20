"""Compare how reliably local models edit a table in RTF, HTML and Markdown.

Each model gets the same table in one format plus an editing request, and must
return the complete edited document via a write_artefact tool call. Outputs are
validated by parsing them (RTF and HTML through macOS's textutil, the converter
TextEdit uses) and comparing the resulting cell grid with the expected one.

Usage: python3 -I scripts/research/eval_formats.py RUNS MODEL [MODEL...]  (needs Ollama; writes results.json to the working directory)
"""
import json
import re
import statistics
import subprocess
import sys
import time
import urllib.request
from html.parser import HTMLParser

BASE = [["Item", "Qty", "Price"], ["Apples", "3", "0.50"], ["Bread", "1", "2.20"], ["Cheese", "2", "4.00"]]

TASKS = [
    ("add column", "Add a Total column (Qty × Price).",
     [["Item", "Qty", "Price", "Total"], ["Apples", "3", "0.50", "1.50"], ["Bread", "1", "2.20", "2.20"], ["Cheese", "2", "4.00", "8.00"]], False),
    ("sort", "Sort the rows by Qty, highest first. Keep the header row at the top.",
     [BASE[0], BASE[1], BASE[3], BASE[2]], False),
    ("delete row", "Remove the Bread row.",
     [BASE[0], BASE[1], BASE[3]], False),
    ("add row", "Add a row: Dates, 5, 3.10.",
     BASE + [["Dates", "5", "3.10"]], False),
    ("bold header", "Make the header row bold.",
     BASE, True),
]


def html_table(rows):
    head = "".join(f"<td>{c}</td>" for c in rows[0])
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows[1:])
    return f"<table>\n<tr>{head}</tr>\n{body}\n</table>"


def markdown_table(rows):
    lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * len(rows[0])]
    lines += ["| " + " | ".join(r) + " |" for r in rows[1:]]
    return "\n".join(lines)


def textutil(data, fmt, to):
    # Malformed RTF can make textutil hang; that counts as unparseable.
    try:
        result = subprocess.run(["textutil", "-stdin", "-stdout", "-format", fmt, "-convert", to],
                                input=data.encode(), capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        print("  (textutil hung on this output)", flush=True)
        return None
    return result.stdout.decode(errors="replace") if result.returncode == 0 else None


# Like TextEdit: an NSAttributedString table written as RTF by Cocoa.
RTF_SOURCE = textutil("<html><body>" + html_table(BASE).replace("<table>", "<table border=1>") + "</body></html>", "html", "rtf")
# The model never edits RTF: Scratchboard converts RTF ↔ HTML itself. The
# question is which format the model edits.
SOURCES = {"HTML": html_table(BASE), "Markdown": markdown_table(BASE)}


class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows, self.cell, self.in_cell = [], [], False

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.rows.append([])
        elif tag in ("td", "th"):
            self.in_cell, self.cell = True, []

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.rows:
            self.rows[-1].append(" ".join("".join(self.cell).split()))
            self.in_cell = False

    def handle_data(self, data):
        if self.in_cell:
            self.cell.append(data)


def grid_from_html(html):
    parser = TableParser()
    parser.feed(html)
    return [r for r in parser.rows if r]


def grid_from_markdown(text):
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|") and line.count("|") < 2:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        rows.append([re.sub(r"^(\*\*|__)(.*)\1$", r"\2", c) for c in cells])
    return rows


def parse(fmt, text):
    """Returns (valid, grid)."""
    text = text.strip()
    text = re.sub(r"^```[a-zA-Z]*\n|\n```$", "", text)
    if fmt == "RTF":
        if not text.startswith("{\\rtf") or text.count("{") != text.count("}"):
            return False, None
        html = textutil(text, "rtf", "html")
    elif fmt == "HTML":
        # What Scratchboard would do: HTML → RTF for the pasteboard, read back.
        rtf = textutil("<html><body>" + text + "</body></html>", "html", "rtf")
        html = textutil(rtf, "rtf", "html") if rtf else None
    else:
        grid = grid_from_markdown(text)
        return bool(grid), grid
    if not html:
        return False, None
    grid = grid_from_html(html)
    return bool(grid), grid


def same(a, b):
    try:
        return abs(float(a) - float(b)) < 1e-6
    except ValueError:
        return a.strip().lower() == b.strip().lower()


def grid_matches(grid, expected):
    return grid is not None and len(grid) == len(expected) and all(
        len(r) == len(e) and all(same(x, y) for x, y in zip(r, e)) for r, e in zip(grid, expected))


def header_bold(fmt, text):
    if fmt == "RTF":
        return bool(re.search(r"\\b(?![a-z])", text))
    if fmt == "HTML":
        first_row = text.split("</tr>")[0]
        return bool(re.search(r"<(b|strong|th)\b|font-weight\s*:\s*(bold|[6-9]00)", first_row))
    first = next((l for l in text.splitlines() if "|" in l), "")
    cells = [c.strip() for c in first.strip().strip("|").split("|")]
    return all(re.fullmatch(r"(\*\*|__).+\1", c) for c in cells if c)


TOOL = {"type": "function", "function": {
    "name": "write_artefact",
    "description": "Replace the document with the complete edited version.",
    "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}}


def run(model, fmt, request):
    instructions = (
        f"You edit a document for the user. The document is {fmt}. Apply the request and call write_artefact "
        f"with the complete edited document, in the same format ({fmt}), valid and complete. Keep everything "
        "the request doesn't change. Put no explanations inside the document.")
    body = json.dumps({"model": model, "stream": False, "tools": [TOOL], "messages": [
        {"role": "system", "content": instructions},
        {"role": "user", "content": f"Document:\n{SOURCES[fmt]}\n\nRequest: {request}"}]}).encode()
    req = urllib.request.Request("http://localhost:11434/v1/chat/completions", body, {"Content-Type": "application/json"})
    start = time.time()
    message = None
    for attempt in range(2):
        try:
            message = json.load(urllib.request.urlopen(req, timeout=600))["choices"][0]["message"]
            break
        except Exception as error:  # e.g. HTTP 500 from the server
            print(f"  (request failed: {error}; attempt {attempt + 1})", flush=True)
            time.sleep(3)
    seconds = time.time() - start
    if message is None:
        return "", seconds
    for call in message.get("tool_calls") or []:
        if call["function"]["name"] == "write_artefact":
            try:
                return json.loads(call["function"]["arguments"]).get("text", ""), seconds
            except json.JSONDecodeError:
                return "", seconds
    return "", seconds


def main():
    runs, models = int(sys.argv[1]), sys.argv[2:]
    print(f"Input sizes: " + ", ".join(f"{f} {len(s)} chars" for f, s in SOURCES.items()), flush=True)
    results = []
    for model in models:
        for fmt in SOURCES:
            for name, request, expected, bold in TASKS:
                for _ in range(runs):
                    text, seconds = run(model, fmt, request)
                    valid, grid = parse(fmt, text) if text else (False, None)
                    correct = valid and grid_matches(grid, expected) and (not bold or header_bold(fmt, text))
                    results.append(dict(model=model, fmt=fmt, task=name, valid=valid, correct=correct,
                                        seconds=seconds, chars=len(text), grid=grid))
                    print(f"{model:24} {fmt:9} {name:12} valid={valid!s:5} correct={correct!s:5} {seconds:5.1f}s {len(text):5}ch", flush=True)
    print("\n| Model | Format | Valid | Correct | Median time | Median output |\n|---|---|---|---|---|---|")
    for model in models:
        for fmt in SOURCES:
            rows = [r for r in results if r["model"] == model and r["fmt"] == fmt]
            print(f"| `{model}` | {fmt} | {sum(r['valid'] for r in rows)}/{len(rows)} | {sum(r['correct'] for r in rows)}/{len(rows)} "
                  f"| {statistics.median(r['seconds'] for r in rows):.1f} s | {int(statistics.median(r['chars'] for r in rows))} chars |")
    print("\n| Format | " + " | ".join(t[0] for t in TASKS) + " |\n|---|" + "---|" * len(TASKS))
    for fmt in SOURCES:
        cells = []
        for name, *_ in TASKS:
            rows = [r for r in results if r["fmt"] == fmt and r["task"] == name]
            cells.append(f"{sum(r['correct'] for r in rows)}/{len(rows)}")
        print(f"| {fmt} | " + " | ".join(cells) + " |")
    json.dump(results, open("results.json", "w"), indent=1)


if __name__ == "__main__":
    main()
