#!/usr/bin/env python3
"""Parse repos.txt into the JSON matrix consumed by the mirror workflow.

Each non-comment, non-blank line is: <sourcehut-owner> <sourcehut-repo>
[github-repo], whitespace-separated (any amount, so columns can be
space-aligned). github-repo defaults to sourcehut-repo when omitted.
"""
import json
import os
import re
import sys

GH_NAME_RE = re.compile(r'^[A-Za-z0-9._-]{1,100}$')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'repos.txt'
    entries = []
    seen_src = {}
    seen_dst = {}
    errors = []

    with open(path, encoding='utf-8') as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.split('#', 1)[0].strip()
            if not line:
                continue
            fields = line.split()
            if len(fields) not in (2, 3):
                errors.append(f'{path}:{lineno}: expected 2 or 3 fields, got {len(fields)}: {raw.strip()!r}')
                continue

            owner, repo = fields[0], fields[1]
            gh_name = fields[2] if len(fields) == 3 else repo

            if not GH_NAME_RE.match(gh_name):
                errors.append(f'{path}:{lineno}: invalid github repo name {gh_name!r}')
                continue

            src_key = (owner, repo)
            if src_key in seen_src:
                errors.append(f'{path}:{lineno}: duplicate source ~{owner}/{repo} (first seen line {seen_src[src_key]})')
                continue
            if gh_name in seen_dst:
                errors.append(f'{path}:{lineno}: duplicate destination repo {gh_name!r} (first seen line {seen_dst[gh_name]})')
                continue

            seen_src[src_key] = lineno
            seen_dst[gh_name] = lineno
            entries.append({'owner': owner, 'repo': repo, 'github_repo': gh_name})

    if errors:
        for e in errors:
            print(f'::error::{e}', file=sys.stderr)
        sys.exit(1)

    if not entries:
        print(f'::error::no mirror entries found in {path}', file=sys.stderr)
        sys.exit(1)

    out = json.dumps({'include': entries})

    gh_out = os.environ.get('GITHUB_OUTPUT')
    if gh_out:
        with open(gh_out, 'a', encoding='utf-8') as f:
            f.write(f'matrix={out}\n')

    print(out)
    print(f'planned {len(entries)} mirror(s)', file=sys.stderr)


if __name__ == '__main__':
    main()
