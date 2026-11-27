#!/usr/bin/env python3
"""Extract the script result from an MCP.ExecuteTypeScript response and save it as pretty JSON.

  python3 scripts/fusion/save-result.py <response-file | -> <out.json>

The response file is either the persisted tool-result file Claude Code writes for large MCP outputs
(path shown in the tool output), or the response text piped on stdin. Accepts the full response
object ({"ok":..,"resultText":..,"result":..}), a fusion_call_result wrapper, or the bare result JSON.
Prints a one-line summary (schema, document, version, counts) so the JSON never has to be read in full.
"""
import json
import re
import sys


def find_result(obj):
    if isinstance(obj, dict):
        if obj.get("schema", "").startswith("fusion-inventory"):
            return obj
        if isinstance(obj.get("result"), (dict, list)):
            return obj["result"]
        if isinstance(obj.get("resultText"), str):
            try:
                return json.loads(obj["resultText"])
            except ValueError:
                return obj["resultText"]
        for key in ("structuredContent", "content", "response"):
            if key in obj:
                r = find_result(obj[key])
                if r is not None:
                    return r
    if isinstance(obj, list):
        for it in obj:
            if isinstance(it, dict) and isinstance(it.get("text"), str):
                try:
                    r = find_result(json.loads(it["text"]))
                except ValueError:
                    continue
                if r is not None:
                    return r
            r = find_result(it)
            if r is not None:
                return r
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    raw = sys.stdin.read() if sys.argv[1] == "-" else open(sys.argv[1], encoding="utf-8").read()
    raw = raw.strip()
    try:
        obj = json.loads(raw)
    except ValueError:
        m = re.search(r"\{.*\}", raw, re.S)  # tolerate leading/trailing non-JSON text
        if not m:
            sys.exit("save-result.py: no JSON found in input")
        obj = json.loads(m.group(0))
    res = find_result(obj)
    if res is None:
        sys.exit("save-result.py: no script result found (did the script set adsk.result?)")
    if isinstance(obj, dict) and obj.get("ok") is False:
        sys.exit(f"save-result.py: script failed: {json.dumps(obj.get('error'))}")
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, ensure_ascii=False)
        f.write("\n")
    if isinstance(res, dict) and "counts" in res:
        d = res.get("document") or {}
        print(f"saved {sys.argv[2]}: {res.get('schema')} | {d.get('name')} v{d.get('version')} | {json.dumps(res['counts'])}")
    else:
        print(f"saved {sys.argv[2]}")


if __name__ == "__main__":
    main()
