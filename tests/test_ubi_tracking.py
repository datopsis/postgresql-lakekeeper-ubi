import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/track-ubi-fixes.py'
spec = importlib.util.spec_from_file_location('tracking', SCRIPT)
tracking = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tracking)


class TrackingTests(unittest.TestCase):
    def test_missing_architecture_is_not_resolved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'vulnerability-summary-amd64.json').write_text(json.dumps({
                'architecture': 'amd64', 'builder': 'pinned', 'findings': [],
            }))
            state = tracking.state_from_reports(root)
        self.assertEqual(len(state['errors']), 1)
        self.assertIn('arm64', state['errors'][0])
        self.assertIn('Incomplete evidence', tracking.render(state, 'https://example.invalid')[1])

    def test_run_link_does_not_change_state_but_publication_does(self):
        state = {'architectures': {'amd64': [{
            'scanner': 'trivy', 'id': 'example-advisory', 'package': 'example',
            'vendor_fixed_versions': ['1.0-2'], 'state': 'deferred',
        }]}, 'errors': []}
        first = tracking.render(state, 'https://example.invalid/1')[0]
        self.assertEqual(first, tracking.render(state, 'https://example.invalid/2')[0])
        state['architectures']['amd64'][0]['state'] = 'blocked'
        self.assertNotEqual(first, tracking.render(state, 'https://example.invalid/3')[0])

    def test_create_then_update_same_issue_comment_only_on_change(self):
        with patch.object(tracking, 'api', side_effect=[[], {'number': 1}]) as api:
            tracking.update_issue('owner/repo', 'new', 'body')
            self.assertEqual(api.call_args.args[:2], ('repos/owner/repo/issues', 'POST'))
        issue = {'number': 1, 'body': tracking.MARKER + '\n<!-- state-sha256:same -->'}
        with patch.object(tracking, 'api', side_effect=[[issue], {}]) as api:
            tracking.update_issue('owner/repo', 'same', 'body')
            self.assertEqual(api.call_count, 2)
            self.assertEqual(api.call_args.args[1], 'PATCH')
        with patch.object(tracking, 'api', side_effect=[[issue], {}, {}]) as api:
            tracking.update_issue('owner/repo', 'changed', 'body')
            self.assertEqual(api.call_count, 3)
            self.assertEqual(api.call_args_list[1].args[:2], ('repos/owner/repo/issues/1/comments', 'POST'))

    def test_duplicate_trackers_fail_closed(self):
        with patch.object(tracking, 'api', return_value=[{'body': tracking.MARKER}] * 2):
            with self.assertRaises(ValueError):
                tracking.update_issue('owner/repo', 'new', 'body')


if __name__ == '__main__':
    unittest.main()
