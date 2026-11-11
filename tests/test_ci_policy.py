"""Guard read-only automation and native/blocking acceptance policy."""
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class CIPolicyTests(unittest.TestCase):
    def test_workflows_are_read_only_pinned_and_do_not_publish(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            with self.subTest(workflow=path.name):
                workflow = yaml.safe_load(path.read_text())
                self.assertEqual(workflow['permissions'], {'contents': 'read'})
                for job in workflow['jobs'].values():
                    self.assertEqual(job.get('permissions', {'contents': 'read'}), {'contents': 'read'})
                    for step in job['steps']:
                        if 'uses' in step:
                            self.assertRegex(step['uses'], r'^[^@]+@[a-f0-9]{40}$')
                        command = step.get('run', '')
                        self.assertIsNone(re.search(r'\b(?:git\s+(?:commit|push)|gh\s+(?:pr|release)|(?:docker|podman)\s+push)\b', command))

    def test_native_matrix_and_unconditional_failure_propagation(self):
        ci = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
        job = ci['jobs']['image']
        self.assertEqual({x['architecture']: x['runner'] for x in job['strategy']['matrix']['include']},
                         {'amd64': 'ubuntu-24.04', 'arm64': 'ubuntu-24.04-arm'})
        gates = [step for step in job['steps'] if 'scripts/vulnerability-gate.py' in step.get('run', '')]
        self.assertEqual(len(gates), 1)
        self.assertNotIn('continue-on-error', gates[0])
        self.assertNotIn('continue-on-error', job)
        self.assertIn('= success', ci['jobs']['image-result']['steps'][0]['run'])


if __name__ == '__main__':
    unittest.main()
