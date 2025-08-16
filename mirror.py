#!/usr/bin/env python3

import os
import subprocess
import sys

REPOS = [
  ('blastwave', 'bw', 'bw'),
  ('bptato', 'chawan', 'chawan'),
  ('dajolly', 'cgbl', 'cgbl'),
  ('ioiojo', 'meka', 'meka'),
  ('jprotopopov', 'kefir', 'kefir'),
  ('mil', 'sxmo-utils', 'sxmo-utils'),
  ('mlb', 'linkhut', 'linkhut'),
  ('sircmpwn', 'drewdevault.com', 'drewdevault.com'),
  ('sircmpwn', 'git.sr.ht', 'git.sr.ht'),
  ('sircmpwn', 'hare', 'hare'),
  ('sircmpwn', 'hare-ev', 'hare-ev'),
  ('sircmpwn', 'himitsu', 'himitsu'),
  ('sircmpwn', 'hub.sr.ht', 'hub.sr.ht'),
  ('thestr4ng3r', 'chiaki', 'chiaki'),
]

def run(cmd: list[str]):
  try:
    subprocess.run(cmd, check=True)
  except subprocess.CalledProcessError as e:
    print(f'Command "{cmd}" failed with exit code {e.returncode}')
    sys.exit(e.returncode)
  except FileNotFoundError:
    print(f'Command "{cmd}" not found')
    sys.exit(1)

if __name__ == '__main__':
  os.chdir(os.path.dirname(__file__))
  os.makedirs('repos', exist_ok=True)

  tok = os.environ.get("GH_MIRROR_TOKEN")
  if not tok:
    print('GH_MIRROR_TOKEN not set')
    sys.exit(1)

  for i, repo in enumerate(REPOS):
    print(f'[{i + 1}/{len(REPOS)}] Mirroring ~{repo[0]}/{repo[1]}')
    repo_url = f'https://git.sr.ht/~{repo[0]}/{repo[1]}'
    repo_dir = f'repos/{repo[1]}'
    repo_dst = f'https://x-access-token:{tok}@github.com/sourcehut-mirrors/{repo[2]}.git'
    if os.path.isdir(repo_dir):
      run(['git', '-C', repo_dir, 'fetch', '-p', 'origin'])
      print('  updated')
    else:
      run(['git', 'clone', '--mirror', repo_url, f'repos/{repo[1]}'])
      print('  cloned')
    run(['git', '-C', repo_dir, 'push', '--mirror', repo_dst])
    print('  pushed')
