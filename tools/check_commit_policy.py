"""Reject co-author trailers and known AI author identities in PR commits."""

import json
import re
import sys


TRAILER = re.compile(r"^\s*co-authored-by\s*:", re.IGNORECASE | re.MULTILINE)
AI_EMAILS = {"noreply@anthropic.com", "noreply@openai.com"}


def violations(commits):
    problems = []
    for item in commits:
        commit = item["commit"]
        sha = item["sha"][:12]
        if TRAILER.search(commit["message"]):
            problems.append(f"{sha}: remove Co-Authored-By trailers")
        for role in ("author", "committer"):
            if commit[role]["email"].strip().casefold() in AI_EMAILS:
                problems.append(f"{sha}: use the human contributor's Git identity as {role}")
    return problems


def main():
    with open(sys.argv[1], encoding="utf-8") as source:
        pages = json.load(source)
    commits = [commit for page in pages for commit in page]
    if not commits:
        raise SystemExit("No PR commits returned; refusing to skip the attribution check")
    problems = violations(commits)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        raise SystemExit(1)
    print(f"Checked {len(commits)} PR commits: human attribution, no co-author trailers")


if __name__ == "__main__":
    main()
