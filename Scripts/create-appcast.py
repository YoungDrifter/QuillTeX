#!/usr/bin/env python3
"""Generate a signed GitHub update feed without exposing or modifying old archives."""
from pathlib import Path
import argparse, os, plistlib, re, shutil, subprocess, tempfile, xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APP = 'QuillTeX' if (ROOT / 'QuillTeX.xcodeproj').exists() else 'PaperLens'
ACCOUNT = 'YoungDrifter.desktop-apps'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('archive_directory', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('expected a semantic release version')
    archive = args.archive_directory.resolve()
    dmg = archive / f'{APP}-{args.version}.dmg'
    destination = archive / 'appcast.xml'
    if destination.exists():
        parser.error('refusing to overwrite an existing signed appcast')
    if not dmg.is_file():
        parser.error('the validated DMG is missing')
    tools = Path(os.environ.get('SPARKLE_SIGNING_TOOLS_DIR', str(ROOT / 'build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin')))
    if not (tools / 'generate_appcast').is_file():
        parser.error('Sparkle tools are missing; build the app first')
    info_path = ROOT / APP / ('App/Info.plist' if APP == 'QuillTeX' else 'PaperLens-Info.plist')
    with info_path.open('rb') as f: public_key = plistlib.load(f)['SUPublicEDKey']
    actual = subprocess.check_output([str(tools / 'generate_keys'), '--account', ACCOUNT, '-p'], text=True).strip()
    if actual != public_key:
        parser.error('the Keychain signing account does not match this app’s public key')
    # Sparkle may prune files in its input directory; only give it a temporary copy.
    with tempfile.TemporaryDirectory(prefix='appcast-', dir=ROOT / 'build') as temporary:
        staging = Path(temporary)
        shutil.copy2(dmg, staging / dmg.name)
        prefix = f'https://github.com/YoungDrifter/{APP}/releases/download/v{args.version}/'
        subprocess.run([str(tools / 'generate_appcast'), '--account', ACCOUNT,
                        '--download-url-prefix', prefix, '--maximum-deltas', '0',
                        '--link', f'https://github.com/YoungDrifter/{APP}/releases/tag/v{args.version}',
                        str(staging)], check=True)
        feed = staging / 'appcast.xml'
        subprocess.run([str(tools / 'sign_update'), '--account', ACCOUNT, str(feed)], check=True)
        subprocess.run([str(tools / 'sign_update'), '--account', ACCOUNT, '--verify', str(feed)], check=True)
        item = ET.parse(feed).getroot().find('channel/item')
        if item is None or item.findtext('sparkle:shortVersionString', namespaces=NS) != args.version:
            raise RuntimeError('generated feed version does not match the release')
        enclosure = item.find('enclosure')
        if enclosure is None or enclosure.attrib['url'] != prefix + dmg.name:
            raise RuntimeError('generated feed download URL does not match the release')
        if int(enclosure.attrib['length']) != dmg.stat().st_size:
            raise RuntimeError('generated feed length does not match the validated DMG')
        signature = enclosure.attrib['{' + NS['sparkle'] + '}edSignature']
        subprocess.run([str(tools / 'sign_update'), '--account', ACCOUNT, '--verify', str(dmg), signature], check=True)
        with destination.open('xb') as output:
            output.write(feed.read_bytes())
    print(f'Signed update feed: {destination}')

if __name__ == '__main__': main()
