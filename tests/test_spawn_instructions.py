"""FT-34 native regression tests; no Herdr/Pi processes or live writes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('spawn_check', ROOT / 'check_spawn_instructions.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ClassificationTests(unittest.TestCase):
    def test_known_herdr_commands(self):
        for text in (
            'herdr agent start reviewer --kind codex --pane <returned-pane-id>',
            'herdr agent start reviewer --kind=codex --pane "$pane" -- -m model',
            'herdr agent start reviewer --kind "Codex" --pane "$pane"',
        ):
            with self.subTest(text=text):
                self.assertEqual(check.classify(text, 'active', []), 'active-spawn')

    def test_prose_and_json_launches(self):
        for text in ('Spawn a Codex worker.', 'Start `codex` in that pane.',
                     'Run codex now.', 'Launch the Codex agent.',
                     '{"agent": "codex"}', '{"command": "codex"}', 'codex exec task'):
            with self.subTest(text=text):
                self.assertEqual(check.classify(text, 'active', []), 'active-spawn')

    def test_support_is_exact_and_path_scoped(self):
        text = 'codex has native `/goal`.'
        allowed = [{'text': text, 'paths': ['pi-goal-contracts/SKILL.md']}]
        self.assertEqual(check.classify(text, 'active', allowed, 'repo/pi-goal-contracts/SKILL.md'), 'reviewed-support')
        self.assertEqual(check.classify(text + ' Spawn a worker.', 'active', allowed, 'repo/pi-goal-contracts/SKILL.md'), 'active-unreviewed')
        self.assertEqual(check.classify(text, 'active', allowed, 'repo/other/SKILL.md'), 'active-unreviewed')

    def test_allowlist_never_pardons_spawn(self):
        text = 'herdr agent start reviewer --kind codex'
        self.assertEqual(check.classify(text, 'active', [{'text': text, 'paths': ['SKILL.md']}], 'SKILL.md'), 'active-spawn')

    def test_historical_and_product_support(self):
        for surface in ('historical', 'product-cli-support', 'published-product-support', 'shadowed-product-skill'):
            with self.subTest(surface=surface):
                self.assertEqual(check.classify('herdr agent start reviewer --kind codex', surface, []), surface + '-spawn-example')

    def test_unselected_is_not_cleaned_or_mistaken_for_loaded(self):
        self.assertEqual(check.classify('{"agent": "codex"}', 'available-unselected', []), 'available-unselected-spawn-example')

    def test_new_dated_prompt_is_still_active(self):
        self.assertEqual(check.repo_surface(Path('.pi/prompts/2026-11-10-spawn.md'), True), 'active')

    def test_product_skill_requires_manifest_shadow(self):
        p = Path('src/apps/herdr/skills/herdr/SKILL.md')
        self.assertEqual(check.repo_surface(p, False), 'active')
        self.assertEqual(check.repo_surface(p, True), 'shadowed-product-skill')


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.put('skills/skills.tsv', 'herdr\trepo\tbitnom/fleet-skills\tfleet manual\n')
        self.put('src/skills/fleet-skills/herdr/SKILL.md', '# Pi fleet\nherdr pane run <pane-id> "pil"\n')
        self.put('src/apps/herdr/skills/herdr/SKILL.md', 'herdr agent start reviewer --kind codex\n')

    def put(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def cli(self, *args):
        return subprocess.run(['python3', str(ROOT / 'check_spawn_instructions.py'), '--repo', str(self.repo), *args], text=True, capture_output=True)

    def test_clean_candidate_retains_support_and_zero_hit_files(self):
        self.put('docs/archive/old.md', 'Spawn a Codex worker.\n')
        self.put('.pi/prompts/new.md', 'Use pil.\n')
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['summary']['active_findings'], 0)
        self.assertEqual(data['summary']['files'], 4)
        self.assertTrue(all(len(f['sha256']) == 64 for f in data['files']))
        self.assertEqual(len(data['hits']), 2)

    def test_new_untracked_prompt_fails(self):
        self.put('.pi/prompts/new.md', 'Spawn a Codex worker.\n')
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(json.loads(result.stdout)['summary']['active_findings'], 1)

    def test_shell_continuation_fails(self):
        self.put('src/skills/fleet-skills/herdr/SKILL.md', 'herdr agent start reviewer \\\n --kind codex --pane "$pane"\n')
        data = check.collect(self.repo)
        hit = next(h for h in data['hits'] if h['classification'] == 'active-spawn')
        self.assertEqual(hit['line'], 1)

    def test_unknown_reference_fails_closed(self):
        self.put('.pi/modes/new.json', '{"prompt":"delegate through codex somehow"}\n')
        self.assertEqual(self.cli().returncode, 1)

    def test_manifest_reversion_exposes_upstream_commands(self):
        self.put('skills/skills.tsv', 'herdr\trepo\tApothic-AI/herdr\tproduct skill\n')
        result = self.cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['summary']['active_findings'], 1)

    def test_installed_overlay_is_read_only_and_exposes_provenance(self):
        home = self.repo / 'fake-home'
        self.put('fake-home/.pi-profile-switch/profiles/leader.json', '{"skills":["herdr","context-economy"]}')
        self.put('fake-home/.pi-profile-switch/profiles/worker.json', '{"skills":["context-economy"]}')
        self.put('fake-home/.pi/agent/settings.json', '{"packages":[]}')
        live = self.put('fake-home/.agents/skills/herdr/SKILL.md', 'herdr agent start reviewer --kind codex\n')
        self.put('fake-home/.agents/skills/context-economy/SKILL.md', 'Rules for pi and codex lanes.\n')
        self.put('src/skills/fleet-skills/context-economy/SKILL.md', 'Rules for Pi fleet lanes.\n')
        before = live.read_bytes()
        current = check.collect(self.repo, home)
        self.assertGreaterEqual(current['summary']['active_findings'], 2)
        candidate = check.collect(self.repo, home, candidate_overlay=True)
        self.assertEqual(candidate['summary']['active_findings'], 0)
        self.assertTrue(any(f['candidate_overlay'] for f in candidate['files']))
        self.assertEqual(live.read_bytes(), before)

    def test_unselected_installed_preset_is_reported(self):
        home = self.repo / 'fake-home'
        for role in ('leader', 'worker'):
            self.put(f'fake-home/.pi-profile-switch/profiles/{role}.json', '{"skills":[]}')
        self.put('fake-home/.pi/agent/settings.json', '{"packages":[]}')
        self.put('fake-home/.agents/skills/cmux-customization/SKILL.md', '{"agent":"codex"}')
        result = check.collect(self.repo, home)
        self.assertTrue(any(h['classification'] == 'available-unselected-spawn-example' for h in result['hits']))

    def test_missing_overlay_file_fails_closed(self):
        home = self.repo / 'fake-home'
        for role in ('leader', 'worker'):
            self.put(f'fake-home/.pi-profile-switch/profiles/{role}.json', '{"skills":["lane-identity"]}')
        self.put('fake-home/.pi/agent/settings.json', '{"packages":[]}')
        self.put('fake-home/.agents/skills/lane-identity/SKILL.md', 'Pi')
        result = check.collect(self.repo, home, candidate_overlay=True)
        self.assertGreater(len(result['errors']), 0)

    def test_manifest_selects_fleet_manual_via_real_resolver(self):
        repo = ROOT.parents[2]
        row = next(line for line in (repo / 'skills/skills.tsv').read_text().splitlines() if line.startswith('herdr\t'))
        self.assertEqual(row.split('\t')[1:3], ['repo', 'bitnom/fleet-skills'])
        manifest = self.put('herdr-only.tsv', row + '\n')
        import os
        env = dict(os.environ, HOME=str(self.repo), AGENTS_SKILLS_DIR=str(self.repo / 'installed'), SKILLS_MANIFEST=str(manifest))
        result = subprocess.run(['bash', str(repo / 'scripts/skills-sync.sh'), 'install', '--dry-run'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(str(ROOT / 'herdr'), result.stdout)
        self.assertNotIn('npx', result.stdout)

    def test_deterministic_output(self):
        self.assertEqual(self.cli().stdout, self.cli().stdout)

    def test_invalid_repo_is_error_not_success(self):
        result = subprocess.run(['python3', str(ROOT / 'check_spawn_instructions.py'), '--repo', str(self.repo / 'missing')], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
