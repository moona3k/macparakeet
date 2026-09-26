#!/usr/bin/env python3
"""Summarize one SwiftPM xUnit report for the GitHub Actions step summary."""

import argparse
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SWIFT_TESTING_RUN = re.compile(
    r"Test run with (?P<tests>\d+) tests?(?: in \d+ suites?)? "
    r"(?P<result>passed|failed) after (?P<seconds>\d+(?:\.\d+)?) seconds?\."
)


def markdown_text(value):
    """Keep XML and log text inside a single, inert Markdown table cell."""
    value = re.sub(r"[\x00-\x1f\x7f]", " ", value)
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("|", "&#124;")
        .replace("`", "&#96;")
        .replace("*", "&#42;")
        .replace("_", "&#95;")
        .replace("[", "&#91;")
        .replace("]", "&#93;")
    )


def duration(case):
    raw = case.get("time")
    if raw is None:
        return None
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"invalid testcase time {raw!r}") from exc
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid testcase time {raw!r}")
    return value


def reported_skips(suites):
    values = [suite.get("skipped") for suite in suites]
    if not values or any(value is None for value in values):
        return None
    try:
        counts = [int(value) for value in values]
    except ValueError as exc:
        raise ValueError("invalid testsuite skipped count") from exc
    if any(count < 0 for count in counts):
        raise ValueError("invalid testsuite skipped count")
    return sum(counts)


def summarize(xml_path, log_path=None):
    try:
        root = ET.parse(xml_path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise ValueError(f"cannot read xUnit XML {xml_path}: {exc}") from exc
    if root.tag == "testsuites":
        suites = root.findall("testsuite")
    elif root.tag == "testsuite":
        suites = [root]
    else:
        raise ValueError(f"unexpected xUnit root element {root.tag!r}")
    if not suites:
        raise ValueError("xUnit XML contains no testsuite")

    cases = [case for suite in suites for case in suite.iter("testcase")]
    if not cases:
        raise ValueError("xUnit XML contains no testcase; test results may be incomplete")

    timed = [(duration(case), case) for case in cases]
    with_time = [(seconds, case) for seconds, case in timed if seconds is not None]
    failed = sum(case.find("failure") is not None for case in cases)
    errors = sum(case.find("error") is not None for case in cases)
    skips = reported_skips(suites)

    lines = [
        "### Swift test results",
        "",
        f"- Cases in xUnit XML: **{len(cases)}**; failures: **{failed}**; errors: **{errors}**.",
        f"- Skipped (suite report): **{skips}**." if skips is not None else "- Skipped: not reported by this xUnit XML.",
    ]
    if with_time:
        lines.append(
            f"- Sum of {len(with_time)} case durations: **{sum(seconds for seconds, _ in with_time):.2f}s** "
            "(parallel tests overlap; this is not wall time)."
        )
    if len(with_time) != len(cases):
        lines.append(f"- Cases without a duration: **{len(cases) - len(with_time)}**.")

    if with_time:
        lines += ["", "Slowest cases in xUnit XML:", "", "| Case | Duration |", "| --- | ---: |"]
        for seconds, case in sorted(with_time, key=lambda item: item[0], reverse=True)[:10]:
            name = ".".join(part for part in (case.get("classname"), case.get("name")) if part)
            lines.append(f"| {markdown_text(name or '(unnamed)')} | {seconds:.2f}s |")

    if log_path is not None:
        try:
            log = log_path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise ValueError(f"cannot read test log {log_path}: {exc}") from exc
        matches = list(SWIFT_TESTING_RUN.finditer(log))
        if matches:
            match = matches[-1]
            noun = "test" if match["tests"] == "1" else "tests"
            lines += [
                "",
                "Swift Testing (separate log summary; not included in the XML counts above): "
                f"{match['tests']} {noun} {match['result']} after {match['seconds']}s.",
            ]

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", type=Path, help="SwiftPM xUnit XML path")
    parser.add_argument("log", nargs="?", type=Path, help="optional swift test log path")
    args = parser.parse_args()
    try:
        sys.stdout.write(summarize(args.xml, args.log))
    except ValueError as exc:
        print(f"test summary error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
