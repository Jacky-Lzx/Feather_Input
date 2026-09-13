#!/usr/bin/env python3
"""Copy the dylib closure into the app and rewrite paths before signing."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve()
target.mkdir(parents=True, exist_ok=True)
seen = {}

def run(*args):
    return subprocess.check_output(args, text=True)

def bundle(path):
    path = path.resolve()
    if path in seen:
        return seen[path]
    name = 'librime.dylib' if path == source else path.name
    dest = target / name
    if dest.exists():
        raise RuntimeError(f'Duplicate library name: {name}')
    seen[path] = name
    shutil.copy2(path, dest)
    dest.chmod(0o755)
    deps = [line.strip().split(' (')[0] for line in run('otool', '-L', str(path)).splitlines()[1:]]
    # The first entry is the library's own install name.
    for dep in deps[1:]:
        if dep.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if not dep.startswith('/'):
            raise RuntimeError(f'Unresolved dependency: {dep} in {path}')
        child = bundle(pathlib.Path(dep))
        subprocess.run(['install_name_tool', '-change', dep, '@loader_path/' + child, str(dest)], check=True)
    subprocess.run(['install_name_tool', '-id', '@loader_path/' + name, str(dest)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(dest)], check=True)
    return name

bundle(source)

# Do not advertise an older OS than any bundled Mach-O actually supports.
minimum = (13, 0)
for binary in target.iterdir():
    info = run('xcrun', 'vtool', '-show-build', str(binary))
    for version in re.findall(r'minos\s+([0-9.]+)', info):
        minimum = max(minimum, tuple(map(int, version.split('.'))))
plist_path = target.parent / 'Info.plist'
with plist_path.open('rb') as stream:
    metadata = plistlib.load(stream)
metadata['LSMinimumSystemVersion'] = '.'.join(map(str, minimum))
with plist_path.open('wb') as stream:
    plistlib.dump(metadata, stream)
