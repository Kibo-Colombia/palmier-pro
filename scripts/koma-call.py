#!/usr/bin/env python3
"""Call the running Koma MCP without automating its UI or retrying mutations."""
import argparse
import json
import sys
import urllib.request


def call(tool, arguments):
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": tool, "arguments": arguments}}
    request = urllib.request.Request("http://127.0.0.1:19789/mcp",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(request, timeout=60) as response:
        envelope = json.load(response)
    if "error" in envelope:
        raise RuntimeError(envelope["error"])
    result = envelope["result"]
    if result.get("isError"):
        raise RuntimeError("; ".join(block.get("text", "") for block in result.get("content", [])))
    texts = [block["text"] for block in result.get("content", []) if block.get("type") == "text"]
    if len(texts) == 1:
        try:
            return json.loads(texts[0])
        except json.JSONDecodeError:
            return {"ok": True, "text": texts[0]}
    return {"ok": True, "texts": texts,
            "imageCount": sum(block.get("type") == "image" for block in result.get("content", []))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool")
    parser.add_argument("--args", type=argparse.FileType("r"), default=None,
                        help="JSON argument file; omit for an empty object")
    options = parser.parse_args()
    arguments = json.load(options.args) if options.args else {}
    if not isinstance(arguments, dict):
        parser.error("arguments must be a JSON object")
    try:
        print(json.dumps(call(options.tool, arguments), indent=2))
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
