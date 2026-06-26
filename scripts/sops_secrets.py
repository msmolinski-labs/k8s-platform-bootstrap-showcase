#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def ensure_sops_available() -> None:
    try:
        subprocess.run(["sops", "--version"], check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        fail(f"sops is required but not available: {exc}")


def load_data(file_path: Path) -> dict:
    if not file_path.exists():
        return {}

    result = subprocess.run(
        ["sops", "--decrypt", str(file_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = result.stdout.strip()
    if not payload:
        return {}

    data = yaml.safe_load(payload) or {}
    if not isinstance(data, dict):
        fail(f"Expected a YAML mapping in {file_path}, got {type(data).__name__}")
    return data


def load_declared_age_recipients(file_path: Path) -> str:
    if not file_path.exists():
        return ""

    try:
        raw_text = file_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"Failed to read SOPS metadata from {file_path}: {exc}")

    raw_data = yaml.safe_load(raw_text) or {}
    if not isinstance(raw_data, dict):
        return ""

    sops_data = raw_data.get("sops") or {}
    age_entries = sops_data.get("age") or []
    recipients = [entry.get("recipient", "") for entry in age_entries if isinstance(entry, dict) and entry.get("recipient")]
    return ",".join(recipients)


def save_data(file_path: Path, data: dict, recipients: str | None) -> None:
    resolved_recipients = (
        recipients
        or os.getenv("BOOTSTRAP_SOPS_AGE_RECIPIENTS")
        or os.getenv("SOPS_AGE_RECIPIENTS")
        or load_declared_age_recipients(file_path)
    )
    if not resolved_recipients:
        fail(
            "Missing age recipients. Set BOOTSTRAP_SOPS_AGE_RECIPIENTS or SOPS_AGE_RECIPIENTS before writing SOPS secrets."
        )

    file_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".yaml") as handle:
        yaml.safe_dump(data, handle, sort_keys=False, default_flow_style=False)
        temp_path = Path(handle.name)

    try:
        subprocess.run(
            [
                "sops",
                "--encrypt",
                "--age",
                resolved_recipients,
                "--output",
                str(file_path),
                str(temp_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    finally:
        temp_path.unlink(missing_ok=True)


def get_nested(data: dict, dotted_key: str):
    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            return ""
        current = current[part]
    return current


def set_nested(data: dict, dotted_key: str, value) -> None:
    current = data
    parts = dotted_key.split(".")
    for part in parts[:-1]:
        next_value = current.get(part)
        if not isinstance(next_value, dict):
            next_value = {}
            current[part] = next_value
        current = next_value
    current[parts[-1]] = value


def delete_nested(data: dict, dotted_key: str) -> None:
    current = data
    parts = dotted_key.split(".")
    for part in parts[:-1]:
        next_value = current.get(part)
        if not isinstance(next_value, dict):
            return
        current = next_value
    current.pop(parts[-1], None)


def parse_key_value(item: str):
    if "=" not in item:
        fail(f"Expected KEY=VALUE pair, got: {item}")
    key, value = item.split("=", 1)
    return key, value


def command_get(args) -> None:
    data = load_data(Path(args.file))
    if args.key:
        value = get_nested(data, args.key)
        if isinstance(value, (dict, list)):
            print(json.dumps(value))
        else:
            print(value)
        return

    print(yaml.safe_dump(data, sort_keys=False, default_flow_style=False), end="")


def command_dump_json(args) -> None:
    data = load_data(Path(args.file))
    print(json.dumps(data))


def command_upsert(args) -> None:
    data = load_data(Path(args.file))
    for item in args.set_items:
        key, value = parse_key_value(item)
        set_nested(data, key, value)
    save_data(Path(args.file), data, args.age_recipients)


def command_delete(args) -> None:
    data = load_data(Path(args.file))
    for key in args.keys:
        delete_nested(data, key)
    save_data(Path(args.file), data, args.age_recipients)


def build_parser():
    parser = argparse.ArgumentParser(description="Read and update SOPS-encrypted YAML secret files.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("--file", required=True)
    get_parser.add_argument("--key")
    get_parser.set_defaults(func=command_get)

    dump_json_parser = subparsers.add_parser("dump-json")
    dump_json_parser.add_argument("--file", required=True)
    dump_json_parser.set_defaults(func=command_dump_json)

    upsert_parser = subparsers.add_parser("upsert")
    upsert_parser.add_argument("--file", required=True)
    upsert_parser.add_argument("--age-recipients")
    upsert_parser.add_argument("--set", dest="set_items", action="append", required=True)
    upsert_parser.set_defaults(func=command_upsert)

    delete_parser = subparsers.add_parser("delete")
    delete_parser.add_argument("--file", required=True)
    delete_parser.add_argument("--age-recipients")
    delete_parser.add_argument("--key", dest="keys", action="append", required=True)
    delete_parser.set_defaults(func=command_delete)

    return parser


def main() -> None:
    ensure_sops_available()
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()