#!/usr/bin/env python3
"""Read-only FT-34 instruction discovery. Stdlib only; never starts an agent.

Exit 0: no unreviewed active Codex text; 1: active finding; 2: discovery error.
JSON includes all files (including zero-hit files), hashes, provenance, and hits.
--installed inventories load roots as well as the isolated repo candidate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
SKIP = {'.git', 'node_modules', '.venv', 'venv', '__pycache__', '.cache'}
TEXT = {'.md', '.mdx', '.txt', '.json', '.yaml', '.yml', '.toml', '.sh', '.ts', '.swift', '.rs', '.py', '.env'}
SPAWN = re.compile(
    r'herdr\s+agent\s+start\b[^\n]*--kind(?:\s+|=)[\x22\x27`]*codex\b'
    r'|\b(?:spawn|start|launch|run)\s+(?:a\s+|an\s+|the\s+)?[\x22\x27`]*codex\b'
    r'|[\x22\x27](?:agent|command)[\x22\x27]\s*:\s*[\x22\x27]codex[\x22\x27]'
    r'|^\s*(?:\$\s*)?codex(?:\s+(?:exec|resume|--[^\s]+)|\s*$)', re.I | re.M)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def walk(root):
    """Follow skill links, but visit each directory once; never traverse sessions."""
    seen = set()
    def fail(exc):
        raise exc
    for directory, dirs, files in os.walk(root, followlinks=True, onerror=fail):
        real = Path(directory).resolve()
        if real in seen:
            dirs[:] = []
            continue
        seen.add(real)
        dirs[:] = sorted(d for d in dirs if d not in SKIP)
        for name in sorted(files):
            p = Path(directory) / name
            if p.suffix in TEXT:
                yield p


def repo_surface(rel, fleet_herdr_selected):
    parts = rel.parts
    s = rel.as_posix()
    if s.startswith('src/skills/fleet-skills/tests/') or rel.name == 'check_spawn_instructions.py' or rel.name == 'codex-support.json':
        return None
    if s.startswith('src/apps/herdr/skills/'):
        return 'shadowed-product-skill' if fleet_herdr_selected else 'active'
    if s.startswith('src/apps/herdr/docs/versions/') or s.startswith('src/apps/herdr/docs/preview/'):
        return 'published-product-support'
    if s.startswith('src/apps/herdr/docs/'):
        return 'product-cli-support'
    if any(x in parts for x in ('archive', 'archives', 'continuations', '.trellis')):
        return 'historical'
    if rel.name in {'AGENTS.md', 'SYSTEM.md', 'APPEND_SYSTEM.md', 'SKILL.md'} or any(x in parts for x in ('prompts', 'templates', 'modes', 'mode-presets')):
        return 'active'
    if re.search(r'\d{4}-\d\d-\d\d', rel.name):
        return 'historical'
    if s.startswith(('src/skills/', 'home/.overlord/skills/')):
        return 'active'
    if s.startswith(('docs/', 'yellowstone-skill/')) or s == 'home/.overlord/bin/pil':
        return 'active'
    if s.startswith(('src/pi-extensions/pi-fleet-hooks/src/', 'src/pi-extensions/pi-modes/src/', 'src/pi-extensions/pi-goal/src/', 'src/pi-extensions/pi-persist/src/', 'src/pi-extensions/pi-profile-switch/src/', 'src/pi-extensions/bizzy/src/', 'src/herdr-plugins/herdr-voice-linux/Sources/')):
        return 'runtime-product-support'
    if rel.suffix in {'.md', '.mdx'} or re.search(r'(prompt|template|spawn)', rel.name, re.I):
        return 'product-cli-support'
    return None


def classify(text, surface, allowed, label=''):
    if surface != 'active':
        return surface + ('-spawn-example' if SPAWN.search(text) else '')
    # A support exception can never pardon a launch command.
    if SPAWN.search(text):
        return 'active-spawn'
    if any(text == x['text'] and any(label.endswith(p) for p in x['paths']) for x in allowed):
        return 'reviewed-support'
    return 'active-unreviewed'


def collect(repo, installed_home=None, agent_dir=None, candidate_overlay=False):
    allow = json.loads((HERE / 'codex-support.json').read_text())
    allowed = allow
    tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-co', '--exclude-standard', '-z']).decode().split('\0')
    manifest = (repo / 'skills/skills.tsv').read_text()
    selected = 'herdr\trepo\tbitnom/fleet-skills\t' in manifest
    inputs = []
    errors = []
    for s in sorted(set(tracked) - {''}):
        p = repo / s
        if not p.is_file() or (p.suffix not in TEXT and p.name != 'pil'):
            continue
        surface = repo_surface(Path(s), selected)
        if surface:
            inputs.append((p, 'repo/' + s, surface))
    roots = []
    if installed_home:
        home = installed_home
        agent = agent_dir or home / '.pi/agent'
        # These are discovery roots, not session/terminal reads. Both profiles
        # are considered so a clean worker filter cannot hide a leader defect.
        selected_names = set()
        for role in ('leader', 'worker'):
            profile = home / '.pi-profile-switch/profiles' / (role + '.json')
            try:
                selected_names.update(json.loads(profile.read_text()).get('skills', []))
            except (OSError, ValueError) as exc:
                errors.append(f'{profile}: {exc}')
        for root in (home / '.agents/skills', agent / 'skills', home / '.pi/agent/skills', home / 'Documents/Fleet/.agents/skills', home / '.overlord/.agents/skills', home / '.overlord/skills', agent / 'pi-hermes-memory/skills', agent / 'projects-memory/yellowstone/skills'):
            roots.append({'path': str(root), 'exists': root.exists()})
            if not root.exists():
                continue
            for p in walk(root):
                name = p.relative_to(root).parts[0]
                surface = 'active' if name in selected_names or 'memory' in str(root) or root == home / '.overlord/skills' else 'available-unselected'
                inputs.append((p, str(p), surface))
        # Ancestor AGENTS plus fleet role/mode and conventional personal prompts.
        bases = dict.fromkeys([home, *repo.parents, home / 'Code/yellowstone', home / 'Documents/Fleet', home / '.overlord', repo])
        for base in bases:
            for name in ('AGENTS.md', 'SYSTEM.md', 'APPEND_SYSTEM.md', '.pi/settings.json', '.pi/launch.env'):
                p = base / name
                if p.is_file():
                    inputs.append((p, str(p), 'active'))
            for name in ('.pi/modes', '.pi/prompts', '.pi/skills', '.agents/skills'):
                root = base / name
                if root.exists():
                    for p in walk(root):
                        inputs.append((p, str(p), 'active'))
        for base in dict.fromkeys((agent, home / '.pi/agent')):
            for name in ('modes', 'mode-presets', 'prompts', 'extensions'):
                root = base / name
                roots.append({'path': str(root), 'exists': root.exists()})
                if root.exists():
                    for p in walk(root):
                        if '.bak' not in p.name:
                            inputs.append((p, str(p), 'active'))
            for name in ('AGENTS.md', 'SYSTEM.md', 'APPEND_SYSTEM.md', 'settings.json', 'pi-persist.json'):
                p = base / name
                if p.exists():
                    inputs.append((p, str(p), 'active'))
        # Package prompt roots, including scoped npm packages and local sources.
        # Read manifests/settings, never install or execute package code.
        settings = json.loads((agent / 'settings.json').read_text())
        package_roots = []
        for entry in settings.get('packages', []):
            source = entry if isinstance(entry, str) else entry['source']
            if source.startswith('npm:'):
                spec = source[4:]
                name = spec.rsplit('@', 1)[0] if '@' in spec[1:] else spec
                package_roots.append(agent / 'npm/node_modules' / name)
            elif source.startswith('/') or source.startswith('~'):
                package_roots.append(Path(source).expanduser())
        for root in package_roots:
            if not root.exists():
                errors.append(f'configured package root unavailable: {root}')
                continue
            manifest_path = root / 'package.json'
            try:
                pkg = json.loads(manifest_path.read_text())
            except (OSError, ValueError) as exc:
                errors.append(f'{manifest_path}: {exc}')
                continue
            # Conventional and manifest-selected prompt templates; include all
            # Markdown in those roots (a conservative superset of package globs).
            prompt_specs = pkg.get('pi', {}).get('prompts', [])
            for spec in ['prompts', *prompt_specs]:
                prefix = re.split(r'[*?\[]', spec.lstrip('!'))[0]
                path = root / prefix
                if path.is_file():
                    inputs.append((path, str(path), 'active'))
                elif path.is_dir():
                    for p in walk(path):
                        inputs.append((p, str(p), 'active'))
        for p in (home / '.pi-profile-switch/profiles').glob('*.json'):
            inputs.append((p, str(p), 'active'))
    files, hits = [], []
    overlay_names = {'herdr', 'context-economy', 'lane-identity'}
    seen = set()
    for path, label, surface in sorted(inputs, key=lambda x: x[1]):
        # Preserve aliases in provenance, but only inspect identical label once.
        if label in seen:
            continue
        seen.add(label)
        source = path
        if candidate_overlay and installed_home:
            for root in (installed_home / '.agents/skills', (agent_dir or installed_home / '.pi/agent') / 'skills', installed_home / '.pi/agent/skills'):
                try:
                    rel = path.relative_to(root)
                except ValueError:
                    continue
                if rel.parts[0] in overlay_names:
                    source = repo / 'src/skills/fleet-skills' / rel
                    break
        try:
            raw = source.read_bytes()
            text = raw.decode()
        except (OSError, UnicodeError) as exc:
            errors.append(f'{label}: {exc}')
            continue
        files.append({'path': label, 'resolved': str(path.resolve()), 'read_source': str(source.resolve()), 'candidate_overlay': source != path, 'surface': surface, 'sha256': digest(raw), 'bytes': len(raw)})
        # Join shell continuations before checking commands; keep first line.
        lines = text.splitlines()
        n = 0
        while n < len(lines):
            start = n + 1
            line = lines[n]
            while line.rstrip().endswith('\\') and n + 1 < len(lines):
                n += 1
                line = line.rstrip()[:-1] + ' ' + lines[n].lstrip()
            if re.search(r'codex', line, re.I):
                hits.append({'path': label, 'line': start, 'text': line, 'classification': classify(line, surface, allowed, label)})
            n += 1
    failures = [h for h in hits if h['classification'] in {'active-spawn', 'active-unreviewed'}]
    return {'schema': 1, 'candidate_overlay': candidate_overlay, 'roots': roots, 'files': files, 'hits': hits, 'errors': errors,
            'summary': {'files': len(files), 'codex_hits': len(hits), 'active_findings': len(failures), 'errors': len(errors)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--installed', action='store_true')
    parser.add_argument('--candidate-overlay', action='store_true', help='read candidate skills in place of installed skill contents, without writing live files')
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--agent-dir', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.candidate_overlay and not args.installed:
            parser.error('--candidate-overlay requires --installed')
        result = collect(args.repo.resolve(), args.home if args.installed else None, args.agent_dir, args.candidate_overlay)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(json.dumps({'errors': [str(exc)]}, sort_keys=True))
        return 2
    encoded = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.write_text(encoded)
        print(json.dumps(result['summary'], sort_keys=True))
    else:
        print(encoded, end='')
    return 2 if result['errors'] else 1 if result['summary']['active_findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
