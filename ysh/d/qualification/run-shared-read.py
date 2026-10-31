#!/usr/bin/env python3
"""Compare the original shared OSH read fixture against native D and Oils.

Python drives the unchanged spec harness only; ysh-d executes source in D.
Expected failures remain visible rather than being waived.
"""
import csv
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RESULTS = ROOT / "ysh/d/.build/inherited-spec"
FIXTURE = "spec/builtin-read.test.sh"


def rows(path):
    with path.open(encoding="utf-8", newline="") as source:
        return list(csv.DictReader(source, delimiter="\t"))


def main():
    native = RESULTS / "native-osh"
    reference = ROOT / "bin/osh"
    if not native.is_file() or not reference.is_file():
        raise RuntimeError("The native OSH wrapper and actual Oils reference must exist")
    result_file = RESULTS / "shared-builtin-read.tsv"
    log_file = RESULTS / "shared-builtin-read.log"
    command = [
        "python2.7", str(ROOT / "test/sh_spec.py"),
        "-v", "--details", "--timeout=3",
        "--tmp-env", str(RESULTS / "tmp/shared-builtin-read"),
        "--path-env", str(ROOT / "spec/bin") + ":" + os.environ["PATH"],
        "--env-pair", "LC_ALL=C.UTF-8",
        "--env-pair", "LOCALE_ARCHIVE=" + os.environ.get("LOCALE_ARCHIVE", ""),
        "--env-pair", "OILS_GC_ON_EXIT=" + os.environ.get("OILS_GC_ON_EXIT", ""),
        "--env-pair", "REPO_ROOT=" + str(ROOT),
        "--env-pair", "LIB_YSH=" + str(ROOT / "stdlib/ysh"),
        "--tsv-output", str(result_file), FIXTURE, str(native), str(reference),
    ]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT) + ":" + str(ROOT / "vendor")
    with log_file.open("w", encoding="utf-8", errors="replace") as log:
        status = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                stderr=subprocess.STDOUT, check=False).returncode
    if not result_file.is_file():
        raise RuntimeError("Original spec harness produced no results (exit {})".format(status))
    records = rows(result_file)
    seen = {}
    for record in records:
        pair = (record["case"], record["shell"])
        if pair in seen:
            raise RuntimeError("duplicate case {}".format(pair))
        seen[pair] = record["result"]
    native_cases = {case for case, shell in seen if shell == "native-osh"}
    reference_cases = {case for case, shell in seen if shell == "osh"}
    if not native_cases or native_cases != reference_cases:
        raise RuntimeError("original read fixture did not produce paired native/reference cases")
    counts = {}
    for label in ("native-osh", "osh"):
        verdicts = [seen[(case, label)] for case in sorted(native_cases, key=int)]
        counts[label] = (sum(v not in ("FAIL", "TIMEOUT") for v in verdicts),
                         sum(v == "FAIL" for v in verdicts),
                         sum(v == "TIMEOUT" for v in verdicts))
    print("shared builtin-read: total={} D matched={} FAIL={} TIMEOUT={} "
          "reference matched={} FAIL={} TIMEOUT={} harness exit={}".format(
              len(native_cases), *counts["native-osh"], *counts["osh"], status))
    print("original fixture={}, results={}, transcript={}".format(
        FIXTURE, result_file.relative_to(ROOT), log_file.relative_to(ROOT)))
    # A partial shell may legitimately fail cases. Missing paired results or
    # a broken harness cannot pass this qualification's acquisition check.
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("shared-read: {}".format(error), file=sys.stderr)
        sys.exit(2)
