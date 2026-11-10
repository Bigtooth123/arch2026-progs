#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*", "", text)
    return text


def find_array(text: str, name: str):
    # Match a C array initializer, including multidimensional arrays.
    m = re.search(
        rf"\b{name}\s*(?:\[[^\]]*\]\s*)+\s*=\s*\{{(.*?)\}}\s*;",
        text,
        flags=re.S,
    )
    if not m:
        raise SystemExit(f"cannot find array {name}")
    body = m.group(1)
    toks = re.findall(r"0[xX][0-9a-fA-F]+|[0-9]+", body)
    return [int(x, 0) for x in toks]


def find_define(text: str, name: str):
    m = re.search(rf"^\s*#\s*define\s+{name}\s+([^\s/]+)", text, flags=re.M)
    if not m:
        return None
    token = m.group(1).rstrip("uUlL")
    return int(token, 0)


def emit_values(out, directive: str, values, per_line: int, width: int):
    mask = (1 << (width * 8)) - 1
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        rendered = ", ".join(f"0x{(v & mask):0{width * 2}x}" for v in chunk)
        out.append(f"    {directive} {rendered}")


def main():
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: gen_rubik_asm_tables.py STATIC_TABLES_H LOOKUP_TABLES_H OUTPUT_INC"
        )

    static_path = Path(sys.argv[1])
    lookup_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    static_text = strip_comments(static_path.read_text())
    lookup_raw = lookup_path.read_text()
    lookup_text = strip_comments(lookup_raw)

    permutation = find_array(static_text, "permutation")
    orientation = find_array(static_text, "orientation")
    near_key = find_array(lookup_text, "rubik_near_key")
    near_info = find_array(lookup_text, "rubik_near_info")
    far_key = find_array(lookup_text, "rubik_far_key")
    far_move = find_array(lookup_text, "rubik_far_move")

    if len(permutation) != 3 * 5040:
        raise SystemExit(f"permutation has {len(permutation)} entries, expected 15120")
    if len(orientation) != 3 * 729:
        raise SystemExit(f"orientation has {len(orientation)} entries, expected 2187")

    near_count = find_define(lookup_raw, "RUBIK_NEAR_COUNT")
    far_count = find_define(lookup_raw, "RUBIK_FAR_COUNT")
    if near_count is None:
        near_count = len(near_key)
    if far_count is None:
        far_count = len(far_key)

    if near_count != len(near_key) or near_count != len(near_info):
        raise SystemExit(
            f"near table mismatch: count={near_count}, keys={len(near_key)}, info={len(near_info)}"
        )
    if far_count != len(far_key) or far_count != len(far_move):
        raise SystemExit(
            f"far table mismatch: count={far_count}, keys={len(far_key)}, moves={len(far_move)}"
        )

    out = [
        "# Auto-generated. Do not edit.",
        f"    .equ RUBIK_NEAR_COUNT, {near_count}",
        f"    .equ RUBIK_FAR_COUNT, {far_count}",
        "    .section .rodata",
        "    .balign 2",
        ".Lrubik_permutation:",
    ]
    emit_values(out, ".half", permutation, 12, 2)
    out += ["    .balign 2", ".Lrubik_orientation:"]
    emit_values(out, ".half", orientation, 12, 2)

    out += ["    .balign 4", ".Lrubik_near_key:"]
    emit_values(out, ".word", near_key, 6, 4)
    out += [".Lrubik_near_info:"]
    emit_values(out, ".byte", near_info, 16, 1)

    out += ["    .balign 4", ".Lrubik_far_key:"]
    emit_values(out, ".word", far_key, 6, 4)
    out += [".Lrubik_far_move:"]
    emit_values(out, ".byte", far_move, 16, 1)
    out.append("")

    output_path.write_text("\n".join(out))
    print(
        f"wrote {output_path}: near={near_count}, far={far_count}, "
        f"permutation={len(permutation)}, orientation={len(orientation)}"
    )


if __name__ == "__main__":
    main()
