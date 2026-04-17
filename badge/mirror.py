#!/usr/bin/env python3

import os
import subprocess
import sys

REPOS = [
  ('blastwave', 'bw', 'bw'),
  ('bptato', 'chawan', 'chawan'),
  ('dajolly', 'cgbl', 'cgbl'),
  ('fijarom', 'fokus', 'fokus'),
  ('ioiojo', 'meka', 'meka'),
  ('jprotopopov', 'kefir', 'kefir'),
  ('mil', 'sxmo-utils', 'sxmo-utils'),
  ('mlb', 'linkhut', 'linkhut'),
  ('sircmpwn', 'betamine', 'betamine'),
  ('sircmpwn', 'bunnix', 'bunnix'),
  ('sircmpwn', 'git.sr.ht', 'git.sr.ht'),
  ('sircmpwn', 'hare', 'hare'),
  ('sircmpwn', 'hare-ev', 'hare-ev'),
  ('sircmpwn', 'himitsu', 'himitsu'),
  ('sircmpwn', 'hub.sr.ht', 'hub.sr.ht'),
  ('sircmpwn', 'man.sr.ht', 'man.sr.ht'),
  ('technomancy', 'fennel', 'fennel'),
  ('thestr4ng3r', 'chiaki', 'chiaki'),
  ('williewillus', 'thdawn', 'thdawn'),
  ('xerool', 'fennel-ls', 'fennel-ls'),
]

def run(cmd: list[str], fatal: bool = True):
  try:
    subprocess.run(cmd, check=True)
    return True
  except subprocess.CalledProcessError as e:
    print(f'::warning::Command "{cmd}" failed with exit code {e.returncode}')
    if fatal:
      sys.exit(e.returncode)
    return False
  except FileNotFoundError:
    print(f'::warning::Command "{cmd}" not found')
    sys.exit(1)
    return False

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
    ok = False
    if os.path.isdir(repo_dir):
      ok = run(['git', '-C', repo_dir, 'fetch', '-p', 'origin'], False)
      print('  updated')
    else:
      ok = run(['git', 'clone', '--mirror', repo_url, f'repos/{repo[1]}'], False)
      print('  cloned')
    if ok:
      run(['git', '-C', repo_dir, 'push', '--mirror', repo_dst])
    print('  pushed')
