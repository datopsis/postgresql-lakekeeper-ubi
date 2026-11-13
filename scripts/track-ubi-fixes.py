#!/usr/bin/env python3
"""Maintain one issue for UBI availability transitions, using complete native evidence."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import subprocess

MARKER = '<!-- ubi-fix-tracker -->'
TITLE = 'Track vendor security fixes pending UBI availability'


def api(path: str, method='GET', payload=None):
    command = ['gh', 'api', path, '--method', method]
    if payload is not None:
        command.extend(['--input', '-'])
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True, timeout=60)
    return json.loads(result.stdout) if result.stdout.strip() else None


def state_from_reports(root: Path) -> dict:
    state = {'architectures': {}, 'errors': []}
    for arch in ('amd64', 'arm64'):
        paths = list(root.rglob(f'vulnerability-summary-{arch}.json'))
        if len(paths) != 1:
            state['errors'].append(f'{arch}: missing or ambiguous gate summary; status unknown, blocks')
            continue
        try:
            report = json.loads(paths[0].read_text())
            if report['architecture'] != arch or not report['builder']:
                raise ValueError('missing or mismatched architecture/builder')
            rows = []
            for item in report['findings']:
                if item['state'] not in ('blocked', 'deferred'):
                    raise ValueError('unknown finding state')
                rows.append({key: item[key] for key in ('scanner', 'id', 'package', 'severity',
                                                       'vendor_fixed_versions', 'state', 'reason')})
            state['architectures'][arch] = sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))
        except (ValueError, KeyError, TypeError) as error:
            state['errors'].append(f'{arch}: invalid summary ({error}); status unknown, blocks')
    return state


def render(state: dict, run_url: str) -> tuple[str, str]:
    fingerprint = hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()
    lines = [MARKER, f'<!-- state-sha256:{fingerprint} -->',
             'Vendor-fixed High/Critical findings are deferred only while fresh native UBI queries',
             'prove the fixed RPM unavailable. Available fixes and query uncertainty block CI.', '',
             f'[CI evidence]({run_url})', '',
             '| Architecture | Scanner | Finding | Package | Vendor fixed version | State |',
             '| --- | --- | --- | --- | --- | --- |']
    for arch, rows in state['architectures'].items():
        for item in rows:
            values = [arch, item['scanner'], item['id'], item['package'],
                      ', '.join(item['vendor_fixed_versions']) or '(missing)', item['state']]
            lines.append('| ' + ' | '.join(html.escape(str(v)).replace('|', '&#124;').replace('\n', ' ')
                                          for v in values) + ' |')
    if not any(state['architectures'].values()) and not state['errors']:
        lines.extend(['', 'No vendor-fixed High/Critical findings remain in either native scan.'])
    if state['errors']:
        lines.extend(['', '**Incomplete evidence — do not interpret as resolved:**', ''])
        lines.extend('- ' + html.escape(error) for error in state['errors'])
    return fingerprint, '\n'.join(lines) + '\n'


def update_issue(repository: str, fingerprint: str, body: str):
    matches = []
    page = 1
    while True:
        issues = api(f'repos/{repository}/issues?state=all&per_page=100&page={page}')
        matches.extend(issue for issue in issues
                       if 'pull_request' not in issue and MARKER in (issue.get('body') or ''))
        if len(issues) < 100:
            break
        page += 1
    if len(matches) > 1:
        raise ValueError('multiple UBI tracking issues; refusing ambiguous update')
    if not matches:
        return api(f'repos/{repository}/issues', 'POST', {'title': TITLE, 'body': body})
    issue = matches[0]
    if f'<!-- state-sha256:{fingerprint} -->' not in (issue.get('body') or ''):
        api(f'repos/{repository}/issues/{issue["number"]}/comments', 'POST',
            {'body': 'UBI fix availability changed.\n\n' + body})
    return api(f'repos/{repository}/issues/{issue["number"]}', 'PATCH', {'body': body, 'state': 'open'})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--run-url', required=True)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        raise ValueError('invalid repository')
    if not args.run_url.startswith(f'https://github.com/{args.repository}/actions/runs/'):
        raise ValueError('invalid CI evidence URL')
    state = state_from_reports(args.reports)
    fingerprint, body = render(state, args.run_url)
    print(body, end='')
    if args.write:
        issue = update_issue(args.repository, fingerprint, body)
        print(issue['html_url'])
    return int(bool(state['errors']))


if __name__ == '__main__':
    raise SystemExit(main())
