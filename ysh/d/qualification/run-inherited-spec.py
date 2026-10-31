#!/usr/bin/env python3
"""Execute the *unchanged* inherited Python-2 spec harness against D and Oils.

Python is the test driver/reference only. It is never a fallback runtime
inside ysh-d or osh-d. Baseline and fixture files are read, never edited.
"""
import argparse
import csv
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "ysh/d/qualification/inherited-cases-native-2026-10-27.tsv"
RESULTS = ROOT / "ysh/d/.build/inherited-spec"


def read_tsv(path):
    with open(path, newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def put_tsv(path, columns, rows):
    with open(path, "w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def run(fixture, mode, python2):
    stem = Path(fixture).name.removesuffix(".test.sh")
    results = RESULTS / (stem + ".tsv")
    log = RESULTS / (stem + ".log")
    candidate_label = "native-osh" if mode == "osh" else "ysh-d"
    reference = ROOT / "bin" / mode
    command = [
        python2, str(ROOT / "test/sh_spec.py"),
        "-v", "--details", "--timeout=3",
        "--tmp-env", str(RESULTS / "tmp" / stem),
        "--path-env", str(ROOT / "spec/bin") + ":" + os.environ["PATH"],
        "--env-pair", "LC_ALL=C.UTF-8",
        "--env-pair", "LOCALE_ARCHIVE=" + os.environ.get("LOCALE_ARCHIVE", ""),
        "--env-pair", "OILS_GC_ON_EXIT=" + os.environ.get("OILS_GC_ON_EXIT", ""),
        "--env-pair", "REPO_ROOT=" + str(ROOT),
        "--env-pair", "LIB_YSH=" + str(ROOT / "stdlib/ysh"),
        "--tsv-output", str(results),
        fixture, str(RESULTS / candidate_label), str(reference),
    ]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT) + ":" + str(ROOT / "vendor")
    with open(log, "w", encoding="utf-8", errors="replace") as output:
        status = subprocess.run(command, cwd=ROOT, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False).returncode
    if not results.is_file():
        raise RuntimeError("Inherited harness produced no TSV for " + fixture +
                           " (exit " + str(status) + "); see " + str(log))
    records = read_tsv(results)
    by_shell = {}
    for item in records:
        key = (int(item["case"]), item["shell"])
        if key in by_shell:
            raise RuntimeError("duplicate harness result " + str(key))
        by_shell[key] = item["result"]
    return by_shell, status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--python2", default="python2.7")
    parser.add_argument("--fixture", help="run one unchanged inherited fixture")
    args = parser.parse_args()
    RESULTS.mkdir(parents=True, exist_ok=True)
    binary = ROOT / "ysh/d/.build/ysh-d"
    if not binary.is_file():
        raise RuntimeError("D executable missing: " + str(binary))
    ysh_alias = RESULTS / "ysh-d"
    if ysh_alias.is_symlink() or ysh_alias.exists():
        ysh_alias.unlink()
    ysh_alias.symlink_to(binary)

    # The original harness exposes $SH, and OSH fixtures test its suffix.
    # The D entrypoint needs argv[0]=osh-d, while the *path* used by a
    # fixture must end in 'osh'.  A one-line exec wrapper supplies both;
    # no shell evaluates any YSH source code.
    osh_wrapper = RESULTS / "native-osh"
    osh_wrapper.write_text(
        "#!/usr/bin/env bash\nexec -a osh-d " +
        __import__("shlex").quote(str(binary)) + ' "$@"\n',
        encoding="utf-8")
    osh_wrapper.chmod(0o755)

    # ENV fixtures derive the YSH sibling by replacing 'osh' in $SH.
    # Keep that sibling executable while preserving YSH mode on argv[0].
    ysh_partner = RESULTS / "native-ysh"
    if ysh_partner.is_symlink() or ysh_partner.exists():
        ysh_partner.unlink()
    ysh_partner.symlink_to(binary)

    previous = read_tsv(BASELINE)
    fixtures = {}
    for item in previous:
        fixture = item["fixture"]
        if args.fixture and args.fixture != fixture:
            continue
        if fixture in fixtures and fixtures[fixture] != item["mode"]:
            raise RuntimeError("Mixed shell modes in " + fixture)
        fixtures[fixture] = item["mode"]
    if not fixtures:
        raise RuntimeError("Unknown fixture: " + str(args.fixture))
    current = []
    failures = []
    fixture_summary = []
    reference_divergences = []
    for fixture, mode in fixtures.items():
        earlier = [item for item in previous if item["fixture"] == fixture]
        found, exit_status = run(fixture, mode, args.python2)
        candidate_label, reference_label = (
            ("native-osh" if mode == "osh" else "ysh-d"), mode)
        counts = {"candidate-matched": 0, "reference-matched": 0,
                  "candidate-failed": 0, "reference-failed": 0}
        for item in earlier:
            number = int(item["case"])
            if (number, candidate_label) not in found or (number, reference_label) not in found:
                raise RuntimeError("Missing inherited case " + fixture + " #" + str(number))
            actual_d = found[(number, candidate_label)]
            actual_ref = found[(number, reference_label)]
            was_d = item["candidate"]
            was_ref = item["reference"]
            matched_d = actual_d not in ("FAIL", "TIMEOUT")
            matched_ref = actual_ref not in ("FAIL", "TIMEOUT")
            counts["candidate-matched" if matched_d else "candidate-failed"] += 1
            counts["reference-matched" if matched_ref else "reference-failed"] += 1
            if was_d == "pass" and not matched_d:
                failures.append((fixture, number, was_d, actual_d))
            if (was_ref == "pass") != matched_ref:
                reference_divergences.append((fixture, number, was_ref, actual_ref))
            current.append({
                "fixture": fixture, "case": number, "mode": mode,
                "oct27-candidate": was_d, "oct31-candidate": actual_d,
                "oct27-reference": was_ref, "oct31-reference": actual_ref,
            })
        fixture_summary.append({
            "fixture": fixture, "mode": mode, "cases": len(earlier),
            **counts, "harness-exit": exit_status,
        })
        print("{}: D {}/{}, reference {}/{}, harness exit {}".format(
            fixture, counts["candidate-matched"], len(earlier),
            counts["reference-matched"], len(earlier), exit_status), flush=True)

    put_tsv(RESULTS / "paired-cases.tsv",
            ["fixture", "case", "mode", "oct27-candidate", "oct31-candidate",
             "oct27-reference", "oct31-reference"], current)
    put_tsv(RESULTS / "fixture-totals.tsv",
            ["fixture", "mode", "cases", "candidate-matched", "reference-matched",
             "candidate-failed", "reference-failed", "harness-exit"], fixture_summary)
    put_tsv(RESULTS / "regressions.tsv", ["fixture", "case", "previous", "current"],
            [dict(zip(("fixture", "case", "previous", "current"), x)) for x in failures])
    put_tsv(RESULTS / "reference-divergences.tsv",
            ["fixture", "case", "previous", "current"],
            [dict(zip(("fixture", "case", "previous", "current"), x)) for x in reference_divergences])
    totals = {key: sum(int(row[key]) for row in fixture_summary)
              for key in ["cases", "candidate-matched", "reference-matched",
                          "candidate-failed", "reference-failed"]}
    print("TOTAL " + " ".join(k + "=" + str(v) for k, v in totals.items()), flush=True)
    print("REGRESSIONS " + str(len(failures)), flush=True)
    print("REFERENCE_BASELINE_DIVERGENCES " + str(len(reference_divergences)), flush=True)
    for entry in failures:
        print("REGRESSION {}:{} {} -> {}".format(*entry), flush=True)
    if reference_divergences:
        # The reference should be runnable before any parity count is trusted.
        # Surface the first diagnostic while retaining the full unmodified
        # harness transcript as an artifact.
        first = reference_divergences[0][0]
        log = RESULTS / (Path(first).name.removesuffix(".test.sh") + ".log")
        if log.is_file():
            print("FIRST DIVERGENT REFERENCE LOG (start):", flush=True)
            print(log.read_text(encoding="utf-8", errors="replace")[:16000], flush=True)
    # The harness's nonzero exit is expected while translation is incomplete.
    # Losing a previously matched case or changing reference expectations is
    # not expected, so those invalidate the qualification.
    lost_reference_matches = sum(1 for _, _, previous, current in
                                 reference_divergences
                                 if previous == "pass" and
                                 current in ("FAIL", "TIMEOUT"))
    print("REFERENCE_LOST_MATCHES " + str(lost_reference_matches), flush=True)
    return 1 if failures or lost_reference_matches else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("inherited-spec: " + str(error), file=sys.stderr)
        sys.exit(2)
