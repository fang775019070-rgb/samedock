#!/usr/bin/env python3
"""Build the local macOS app with the installed Command Line Tools."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
parser.add_argument('--signing-identity', default=os.environ.get('SAMEDOCK_SIGNING_IDENTITY'),
                    help='SHA-1 fingerprint of the persistent code-signing certificate')
parser.add_argument('--allow-ad-hoc', action='store_true',
                    help='Development only: use a build-specific identity that cannot preserve permissions')
parser.add_argument('--developer-id', action='store_true',
                    help='Public distribution: require an Apple Developer ID identity and secure timestamp')
parser.add_argument('--version', default='1.1.10')
parser.add_argument('--build-number', default='2026111202')
args = parser.parse_args()
if args.allow_ad_hoc and args.signing_identity:
    parser.error('Choose a persistent signing identity or explicit development ad-hoc signing, not both.')
if not args.allow_ad_hoc and not re.fullmatch(r'[0-9a-fA-F]{40}', args.signing_identity or ''):
    parser.error('Signed builds require a certificate SHA-1 via --signing-identity or SAMEDOCK_SIGNING_IDENTITY.')
if args.developer_id:
    if args.allow_ad_hoc:
        parser.error('Developer ID distribution cannot use ad-hoc signing.')
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                               check=True, capture_output=True, text=True).stdout
    if not re.search(r'\b' + re.escape(args.signing_identity) + r'\s+"Developer ID Application:',
                     identities, re.IGNORECASE):
        parser.error('The selected certificate is not an available Developer ID Application identity.')
    if subprocess.run(['git', 'status', '--porcelain'], cwd=root,
                      check=True, capture_output=True, text=True).stdout.strip():
        parser.error('Commit the exact source before creating a public distribution build.')
signing_identity = '-' if args.allow_ad_hoc else args.signing_identity
destination = args.destination.resolve()
if destination.suffix != '.app' or destination.exists():
    parser.error('Choose a new .app build directory; never build over an existing or installed application.')
contents = destination / 'Contents'
resources = contents / 'Resources'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
if args.developer_id:
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                              check=True, capture_output=True, text=True).stdout.strip()
    (resources / 'BuildInfo.json').write_text(json.dumps({'source_commit': revision}) + '\n')
sources = sorted(str(p) for p in (root / 'EchoDock').rglob('*.swift'))
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-O',
    '-module-name', 'EchoDock', '-target', 'arm64-apple-macosx13.0',
    *sources, '-o', str(contents / 'MacOS/SameDock')], check=True)
for name in ['AppIcon.icns', 'AppIcon.png']:
    shutil.copy2(root / 'EchoDock/Resources' / name, resources / name)
for name in ['LICENSE', 'NOTICE.md']:
    shutil.copy2(root / name, resources / name)
catalog = json.loads((root / 'EchoDock/Resources/Localizable.xcstrings').read_text())
for language in ['en', 'zh-Hans']:
    localized = {}
    for key, value in catalog['strings'].items():
        unit = value.get('localizations', {}).get(language, {}).get('stringUnit', {})
        if 'value' in unit:
            localized[key] = unit['value']
    directory = resources / (language + '.lproj')
    directory.mkdir(exist_ok=True)
    # .strings accepts an XML property-list dictionary, preserving format strings.
    (directory / 'Localizable.strings').write_bytes(plistlib.dumps(localized))
info = plistlib.loads((root / 'EchoDock-Info.plist').read_bytes())
info.update(CFBundleExecutable='SameDock', CFBundleIdentifier='app.docklune.mac',
    CFBundleName='SameDock', CFBundleDisplayName='SameDock', CFBundleShortVersionString=args.version,
    CFBundleVersion=args.build_number, CFBundleDevelopmentRegion='en',
    CFBundleLocalizations=['en', 'zh-Hans'], NSHighResolutionCapable=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
(contents / 'PkgInfo').write_bytes(b'APPL????')
signing_arguments = ['codesign', '--force', '--sign', signing_identity]
if not args.allow_ad_hoc:
    signing_arguments += ['--options', 'runtime']
if args.developer_id:
    signing_arguments += ['--timestamp']
subprocess.run([*signing_arguments, str(destination)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
requirement = subprocess.run(['codesign', '--display', '--requirements', '-', str(destination)],
                             check=True, capture_output=True, text=True)
designated_requirement = next((line for line in (requirement.stdout + requirement.stderr).splitlines()
                               if line.startswith('designated =>')), '')
if not args.allow_ad_hoc and (not re.search(r'\b(certificate|anchor)\b', designated_requirement)
                             or 'identifier "app.docklune.mac"' not in designated_requirement):
    raise RuntimeError('Release identity must bind app.docklune.mac to a certificate, not only an identifier or cdhash.')
if not args.allow_ad_hoc:
    details = subprocess.run(['codesign', '--display', '--verbose=4', str(destination)],
                             check=True, capture_output=True, text=True)
    if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n]*\bruntime\b', details.stdout + details.stderr):
        raise RuntimeError('Release signature must enable Hardened Runtime.')
if args.developer_id:
    from scripts.release_macos import verify_app
    verify_app(destination, notarized=False)
print(destination)
