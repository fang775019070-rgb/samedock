#!/usr/bin/env python3
"""Prepare, notarize and verify SameDock without installing it or changing macOS security."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

BUNDLE_ID = 'app.docklune.mac'  # Preserve preferences and the established application identity.
APP_NAME = 'SameDock.app'
APPLE_REQUIREMENT = ('anchor apple generic and '
                     'certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
FORBIDDEN_ENTITLEMENTS = {
    'com.apple.security.get-task-allow',
    'com.apple.security.cs.allow-jit',
    'com.apple.security.cs.allow-unsigned-executable-memory',
    'com.apple.security.cs.allow-dyld-environment-variables',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.cs.disable-executable-page-protection',
}


class ReleaseError(Exception):
    pass


def run(command: list[str], label: str, timeout: int = 60, stdout_only: bool = False) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise ReleaseError(f'{label} timed out; do not assume a remote submission failed.') from exc
    if result.returncode:
        raise ReleaseError(f'{label} failed (exit {result.returncode}).')
    return result.stdout if stdout_only else result.stdout + result.stderr


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path: Path, value: dict) -> None:
    # A partially written file must never appear as a valid release record.
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)


def verify_app(app: Path, team_id: str | None = None, notarized: bool = True) -> dict:
    if not app.is_dir() or app.is_symlink() or app.name != APP_NAME:
        raise ReleaseError('Expected a standalone SameDock.app bundle.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'SameDock':
        raise ReleaseError('Application identity does not match SameDock.')
    if not re.fullmatch(r'\d+\.\d+\.\d+', info.get('CFBundleShortVersionString', '')):
        raise ReleaseError('Expected a numeric release version.')
    if not re.fullmatch(r'\d+', info.get('CFBundleVersion', '')):
        raise ReleaseError('Expected a numeric build number.')
    for resource in ('LICENSE', 'NOTICE.md', 'AppIcon.icns',
                     'en.lproj/Localizable.strings', 'zh-Hans.lproj/Localizable.strings'):
        if not (app / 'Contents/Resources' / resource).is_file():
            raise ReleaseError(f'Required bundled resource missing: {resource}')
    run(['codesign', '--verify', '--deep', '--strict', str(app)], 'Code signature verification')
    # Checking a certificate name alone is insufficient: a self-signed certificate
    # can use any name. Require the Apple trust anchor and Developer ID leaf OID.
    run(['codesign', '--verify', '--strict', '--test-requirement', APPLE_REQUIREMENT, str(app)],
        'Apple Developer ID trust verification')
    details = run(['codesign', '--display', '--verbose=4', str(app)], 'Signature inspection')
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.MULTILINE)
    if not team or (team_id is not None and team.group(1) != team_id):
        raise ReleaseError('Apple signing team does not match the expected team.')
    if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n]*\bruntime\b', details):
        raise ReleaseError('Hardened Runtime is required.')
    if not re.search(r'^Timestamp=.+$', details, re.MULTILINE):
        raise ReleaseError('An Apple secure signing timestamp is required.')
    build_info = json.loads((app / 'Contents/Resources/BuildInfo.json').read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', build_info.get('source_commit', '')):
        raise ReleaseError('A signed source revision is required for the corresponding-source archive.')
    entitlements = run(['codesign', '--display', '--entitlements', ':-', str(app)],
                       'Entitlement inspection')
    start, end = entitlements.find('<?xml'), entitlements.rfind('</plist>')
    if start >= 0 and end >= start:
        values = plistlib.loads(entitlements[start:end + len('</plist>')].encode())
        if any(values.get(key) for key in FORBIDDEN_ENTITLEMENTS):
            raise ReleaseError('Unexpected security exception in release entitlements.')
    binary = app / 'Contents/MacOS/SameDock'
    architectures = run(['lipo', '-archs', str(binary)], 'Architecture inspection').strip().split()
    if not architectures or set(architectures) - {'arm64', 'x86_64'} or 'arm64' not in architectures:
        raise ReleaseError('Unexpected executable architectures.')
    if notarized:
        run(['xcrun', 'stapler', 'validate', str(app)], 'Attached notarization ticket verification')
        assessment = run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)],
                         'Gatekeeper assessment')
        if 'source=Notarized Developer ID' not in assessment:
            raise ReleaseError('Gatekeeper did not identify a notarized Developer ID release.')
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'bundle_id': BUNDLE_ID, 'team_id': team.group(1), 'architectures': architectures,
            'source_commit': build_info['source_commit'],
            'binary_sha256': sha256(binary), 'notarized': notarized}


def inspect_archive(archive: Path) -> None:
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ReleaseError('Archive exceeds the release size limit.')
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if not entries or len(entries) > 5000 or sum(e.file_size for e in entries) > MAX_ARCHIVE_BYTES:
            raise ReleaseError('Archive has an unexpected expanded size or entry count.')
        seen = set()
        for entry in entries:
            name = entry.filename
            path = PurePosixPath(name)
            if (path.is_absolute() or '..' in path.parts or '\\' in name
                    or not path.parts or path.parts[0] not in {APP_NAME, '__MACOSX'}
                    or name in seen):
                raise ReleaseError('Archive contains an unexpected or unsafe path.')
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ReleaseError('This release format does not permit archive symlinks.')
            seen.add(name)
        if f'{APP_NAME}/Contents/Info.plist' not in seen:
            raise ReleaseError('Archive does not contain SameDock.app.')


def verify_archive(archive: Path, team_id: str) -> dict:
    inspect_archive(archive)
    digest = sha256(archive)
    with tempfile.TemporaryDirectory(prefix='samedock-release-check-') as temp:
        run(['ditto', '-x', '-k', str(archive), temp], 'Archive extraction')
        metadata = verify_app(Path(temp) / APP_NAME, team_id, notarized=True)
    if sha256(archive) != digest:
        raise ReleaseError('Archive changed during verification.')
    return {**metadata, 'archive': archive.name, 'archive_sha256': digest,
            'archive_bytes': archive.stat().st_size}


def prepare(app: Path, directory: Path, team_id: str) -> dict:
    metadata = verify_app(app, team_id, notarized=False)
    if directory.exists():
        raise ReleaseError('Use a new release directory; previous submissions must not be overwritten.')
    directory.mkdir(parents=True)
    staged = directory / APP_NAME
    run(['ditto', str(app), str(staged)], 'Staging application')
    if verify_app(staged, team_id, notarized=False) != metadata:
        raise ReleaseError('Staged application does not match the input.')
    archive = directory / 'notarization-input.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(staged), str(archive)],
        'Notarization input packaging')
    state = {'stage': 'prepared', 'app': metadata, 'input_sha256': sha256(archive)}
    write_json(directory / 'notarization-state.json', state)
    return state


def read_state(directory: Path) -> dict:
    state = json.loads((directory / 'notarization-state.json').read_text())
    if sha256(directory / 'notarization-input.zip') != state['input_sha256']:
        raise ReleaseError('Notarization input changed; use a new release directory.')
    if verify_app(directory / APP_NAME, state['app']['team_id'], notarized=False) != state['app']:
        raise ReleaseError('Staged application changed; use a new release directory.')
    return state


def export_source(directory: Path, metadata: dict) -> Path:
    source = directory / f"SameDock-{metadata['version']}-source.zip"
    root = Path(__file__).resolve().parents[1]
    paths = ['EchoDock', 'EchoDockTests', 'EchoDock-Info.plist', 'Package.swift',
             'build-local.py', 'scripts/make-icon.swift', 'scripts/release_macos.py',
             'LICENSE', 'NOTICE.md', 'README.md', 'README.zh-CN.md', 'CHANGELOG.md']
    # Always derive the source from the revision sealed inside the signed app.
    # Compare contents when resuming; zip entry timestamps need not be identical.
    with tempfile.TemporaryDirectory(prefix='samedock-source-') as temp:
        candidate = Path(temp) / source.name
        run(['git', '-C', str(root), 'archive', '--format=zip', '--prefix=SameDock-source/',
             '-o', str(candidate), metadata['source_commit'], '--', *paths], 'Corresponding-source export')
        with zipfile.ZipFile(candidate, 'a') as bundle:
            bundle.writestr('SameDock-source/SOURCE_REVISION.txt', metadata['source_commit'] + '\n')
        if source.exists():
            with zipfile.ZipFile(candidate) as expected, zipfile.ZipFile(source) as actual:
                if (sorted(actual.namelist()) != sorted(expected.namelist())
                        or any(actual.read(n) != expected.read(n) for n in expected.namelist())):
                    raise ReleaseError('Existing corresponding-source archive differs from the signed revision.')
        else:
            # Write after the export succeeds; interrupted exports are never reused.
            with source.open('xb') as stream:
                stream.write(candidate.read_bytes())
    return source


def submit(directory: Path, profile: str) -> dict:
    state = read_state(directory)
    if state['stage'] != 'prepared' or state.get('submission_id'):
        raise ReleaseError('Submission already attempted. Check its saved ID or notarytool history; do not resubmit.')
    # Persist the attempt BEFORE the upload. If the connection dies after Apple
    # accepts it, the next run must recover the ID rather than submit a duplicate.
    state['stage'] = 'submission_started'
    write_json(directory / 'notarization-state.json', state)
    result = json.loads(run(['xcrun', 'notarytool', 'submit', str(directory / 'notarization-input.zip'),
                             '--keychain-profile', profile, '--output-format', 'json', '--no-wait'],
                            'Notarization submission', timeout=180, stdout_only=True))
    identifier = result.get('id', '')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', identifier):
        raise ReleaseError('Submission returned no usable ID; recover it from notarytool history.')
    state.update(stage='submitted', submission_id=identifier)
    write_json(directory / 'notarization-state.json', state)
    return state


def check_status(directory: Path, profile: str) -> dict:
    state = read_state(directory)
    if not state.get('submission_id'):
        raise ReleaseError('No saved submission ID. Inspect notarytool history if an upload was interrupted.')
    result = json.loads(run(['xcrun', 'notarytool', 'info', state['submission_id'],
                             '--keychain-profile', profile, '--output-format', 'json'],
                            'Notarization status', stdout_only=True))
    if result.get('id') != state['submission_id']:
        raise ReleaseError('Notarization response does not match the saved submission.')
    state['apple_status'] = result.get('status', 'Unknown')
    state['stage'] = 'accepted' if state['apple_status'] == 'Accepted' else 'submitted'
    write_json(directory / 'notarization-state.json', state)
    return state


def finalize(directory: Path) -> dict:
    state = read_state(directory)
    if state['stage'] != 'accepted' or state.get('apple_status') != 'Accepted' or not state.get('submission_id'):
        raise ReleaseError('Apple must accept this submission before it can be finalized.')
    app = directory / APP_NAME
    run(['xcrun', 'stapler', 'staple', str(app)], 'Attaching notarization ticket')
    verify_app(app, state['app']['team_id'], notarized=True)
    architecture = 'universal' if len(state['app']['architectures']) > 1 else 'arm64'
    archive = directory / f"SameDock-{state['app']['version']}-{architecture}.zip"
    if not archive.exists():
        with tempfile.TemporaryDirectory(prefix='package-', dir=directory) as temp:
            candidate = Path(temp) / archive.name
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(candidate)],
                'Final distribution packaging')
            verify_archive(candidate, state['app']['team_id'])
            candidate.rename(archive)
    metadata = verify_archive(archive, state['app']['team_id'])
    if any(metadata[key] != value for key, value in state['app'].items() if key != 'notarized'):
        raise ReleaseError('Final archive differs from the application accepted for notarization.')
    source = export_source(directory, metadata)
    metadata.update(submission_id=state['submission_id'],
                    verified_at=datetime.now(timezone.utc).isoformat(),
                    status='notarized_archive_verified',
                    first_download_launch='not_yet_verified', source_archive=source.name,
                    source_sha256=sha256(source), source_bytes=source.stat().st_size)
    write_json(directory / 'release-manifest.json', metadata)
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('preflight')
    prep = actions.add_parser('prepare')
    prep.add_argument('app', type=Path)
    prep.add_argument('directory', type=Path)
    prep.add_argument('--team-id', required=True)
    for name in ('submit', 'status', 'finalize'):
        item = actions.add_parser(name)
        item.add_argument('directory', type=Path)
        if name != 'finalize':
            item.add_argument('--keychain-profile', required=True)
    verify = actions.add_parser('verify')
    verify.add_argument('archive', type=Path)
    verify.add_argument('--team-id', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'preflight':
            run(['xcrun', '--find', 'notarytool'], 'notarytool availability')
            run(['xcrun', '--find', 'stapler'], 'stapler availability')
            identities = run(['security', 'find-identity', '-v', '-p', 'codesigning'], 'Signing identities')
            count = len(re.findall(r'"Developer ID Application:', identities))
            result = {'developer_id_identities': count, 'notarytool': True, 'stapler': True,
                      'ready_for_signing': count > 0, 'notarized': False}
        elif args.action == 'prepare':
            result = prepare(args.app.resolve(), args.directory.resolve(), args.team_id)
        elif args.action == 'submit':
            result = submit(args.directory.resolve(), args.keychain_profile)
        elif args.action == 'status':
            result = check_status(args.directory.resolve(), args.keychain_profile)
        elif args.action == 'finalize':
            result = finalize(args.directory.resolve())
        else:
            result = verify_archive(args.archive.resolve(), args.team_id)
        print(json.dumps(result, indent=2))
    except (ReleaseError, OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        parser.exit(1, f'Release stopped: {exc}\n')


if __name__ == '__main__':
    main()
