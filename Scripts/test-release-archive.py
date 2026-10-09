#!/usr/bin/env python3
"""Exercise archive retention with stubbed Xcode/signing/disk-image tools on macOS."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAME = 'QuillTeX' if (ROOT / 'QuillTeX.xcodeproj').exists() else 'PaperLens'
SCRIPT = Path('Scripts/release.sh' if NAME == 'QuillTeX' else 'scripts/build-local.sh')
STUB = '''import os, plistlib, shutil, sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
root=Path(os.environ['ARCHIVE_TEST_ROOT'])
app=os.environ['ARCHIVE_TEST_APP']
fail=os.environ.get('ARCHIVE_TEST_FAIL','')
with (root/'calls').open('a') as f:f.write(name+' '+' '.join(args)+'\\n')
if name=='xcodebuild':
    if '-showBuildSettings' in args:
        print('    MARKETING_VERSION = 1.1.0')
    else:
        if fail=='build':sys.exit(1)
        out=Path(args[args.index('-derivedDataPath')+1])/'Build/Products/Release'/f'{app}.app/Contents'
        out.mkdir(parents=True)
        with (out/'Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleShortVersionString':'1.2.0' if fail=='version' else '1.1.0'},f)
elif name=='codesign':
    if fail=='sign':sys.exit(1)
elif name=='hdiutil':
    action=args[0]
    if fail==action:sys.exit(1)
    if action=='create':
        (root/'image-input').write_text(args[args.index('-srcfolder')+1])
        Path(args[-1]).write_bytes(b'validated fixture dmg')
    elif action=='verify' and fail=='concurrent':
        winner=root/'release/1.1.0'
        winner.mkdir()
        (winner/'winner.dmg').write_bytes(b'concurrent winner')
    elif action=='attach':
        source=Path((root/'image-input').read_text())
        mount=Path(args[args.index('-mountpoint')+1])
        shutil.copytree(source,mount,dirs_exist_ok=True,symlinks=True)
'''


def snapshot(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}


def run_case(failure):
    with tempfile.TemporaryDirectory(prefix=f'{NAME}-archive-test-') as tmp:
        root = Path(tmp)
        script = root / SCRIPT
        script.parent.mkdir()
        shutil.copy2(ROOT / SCRIPT, script)
        (script.parent / 'create-appcast.py').write_text("import os,sys\nfrom pathlib import Path\nif os.environ.get('ARCHIVE_TEST_FAIL') == 'appcast': sys.exit(1)\n(Path(sys.argv[2])/'appcast.xml').write_text('signed fixture feed')\n")
        (root / f'{NAME}.xcodeproj').mkdir()
        older = root / 'release/1.0.0'
        older.mkdir(parents=True)
        (older / f'{NAME}-1.0.0.dmg').write_bytes(b'permanent original release')
        (older / 'SHA256SUMS.txt').write_bytes(b'original checksum')
        # Legacy build-dir DMGs must also survive packaging cleanup.
        (root / 'build').mkdir()
        legacy = root / 'build' / f'{NAME}-0.9.0.dmg'
        legacy.write_bytes(b'legacy release')
        if failure == 'existing':
            current = root / 'release/1.1.0'
            current.mkdir()
            (current / f'{NAME}-1.1.0.dmg').write_bytes(b'existing release')
            (current / 'SHA256SUMS.txt').write_bytes(b'existing checksum')
        before = snapshot(root / 'release')
        bins = root / 'bin'
        bins.mkdir()
        for command in ['xcodebuild', 'codesign', 'hdiutil']:
            p = bins / command
            p.write_text(f'#!{sys.executable}\n' + STUB)
            p.chmod(0o755)
        env = dict(os.environ, PATH=f'{bins}:' + os.environ['PATH'],
                   ARCHIVE_TEST_ROOT=str(root), ARCHIVE_TEST_APP=NAME,
                   ARCHIVE_TEST_FAIL=failure)
        result = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == (failure == ''), result.stdout + result.stderr
        after = snapshot(root / 'release')
        assert all(after.get(p) == digest for p, digest in before.items()), 'changed published archive'
        assert legacy.read_bytes() == b'legacy release', 'deleted legacy DMG'
        assert not list((root / 'build').glob('.package.*')), 'leaked packaging staging'
        if failure == '':
            subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS.txt'],
                           cwd=root / 'release/1.1.0', check=True, capture_output=True)
        elif failure == 'concurrent':
            assert (root / 'release/1.1.0/winner.dmg').read_bytes() == b'concurrent winner'
            assert not (root / 'release/1.1.0' / f'{NAME}-1.1.0.dmg').exists()
        elif failure != 'existing':
            assert after == before, 'published files after failed validation'
        if failure == 'existing':
            assert ' -derivedDataPath ' not in (root / 'calls').read_text(), 'built before rejecting archive'
        print(f'{NAME}: {failure or "successful publication"} — archive preserved')


if __name__ == '__main__':
    for case in ['', 'existing', 'build', 'version', 'sign', 'create', 'verify', 'attach', 'appcast', 'concurrent']:
        run_case(case)
