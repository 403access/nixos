#!/usr/bin/env python3
"""Small hivexregedit stand-in used by the offline registry tests.

It implements just the subset the slim-image scripts use:

  fake-hivexregedit --export --prefix PREFIX HIVE KEY
  fake-hivexregedit --merge  --prefix PREFIX HIVE FILE

State is stored next to the hive in HIVE.json.  The real hive bytes are never
read, which keeps the tests independent of libhivex and of Windows binaries.
"""

import json
import os
import re
import sys

HEADER = "Windows Registry Editor Version 5.00\n\n"


def state_path(hive):
    return hive + ".json"


def load_state(hive):
    path = state_path(hive)
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        raw = json.load(handle)
    return {key.lower(): dict(values) for key, values in raw.items()}


def save_state(hive, state):
    with open(state_path(hive), "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)


def split_args(argv):
    if len(argv) < 5 or argv[0] not in ("--export", "--merge"):
        raise SystemExit("usage: fake-hivexregedit --export|--merge --prefix PREFIX HIVE KEY|FILE")
    mode = argv[0]
    prefix = None
    rest = []
    index = 1
    while index < len(argv):
        if argv[index] == "--prefix":
            prefix = argv[index + 1]
            index += 2
        else:
            rest.append(argv[index])
            index += 1
    if prefix is None or len(rest) != 2:
        raise SystemExit("missing --prefix or hive/key")
    return mode, prefix, rest[0], rest[1]


def full_key(prefix, key):
    return (prefix.rstrip("\\") + "\\" + key.strip("\\")).lower()


def quote(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def export_key(prefix, hive, key):
    state = load_state(hive)
    target = full_key(prefix, key)
    values = state.get(target)
    out = [HEADER.rstrip("\n")]
    if values is None:
        out.append("")
        out.append("[%s\\%s]" % (prefix, key.strip("\\")))
    else:
        out.append("")
        out.append("[%s\\%s]" % (prefix, key.strip("\\")))
        for name, value in sorted(values.items()):
            if isinstance(value, int):
                out.append('"%s"=dword:%08x' % (name, value))
            else:
                out.append('"%s"="%s"' % (name, quote(str(value))))
    print("\n".join(out))


def parse_hex_string(raw):
    try:
        data = bytes(int(part, 16) for part in raw.split(","))
    except ValueError:
        return raw
    try:
        return data.decode("utf-16-le").rstrip("\x00")
    except UnicodeDecodeError:
        return raw


def parse_value(raw):
    raw = raw.strip()
    if raw.startswith("dword:"):
        return int(raw.split(":", 1)[1], 16)
    if raw.startswith("hex(1):"):
        return parse_hex_string(raw.split(":", 1)[1])
    if raw.startswith("hex(2):"):
        return parse_hex_string(raw.split(":", 1)[1])
    if raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1].replace('\\\\', '\\').replace('\\"', '"')
    return raw


def merge_file(prefix, hive, regfile):
    state = load_state(hive)
    current = None
    with open(regfile, "r", encoding="utf-8-sig") as handle:
        for line in handle:
            line = line.rstrip("\r\n")
            stripped = line.strip()
            if not stripped or stripped.startswith(";"):
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                current = full_key(prefix, stripped[1:-1])
                state.setdefault(current, {})
                continue
            match = re.match(r'^(@|"[^"]+")\s*=\s*(.*)$', stripped)
            if not match or current is None:
                continue
            name = match.group(1)
            if name.startswith('"'):
                name = name[1:-1]
            state[current][name] = parse_value(match.group(2))
    save_state(hive, state)


def main(argv):
    mode, prefix, hive, target = split_args(argv)
    if mode == "--export":
        export_key(prefix, hive, target)
    else:
        merge_file(prefix, hive, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))