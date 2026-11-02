#!/bin/bash
set -euo pipefail
# The workflows are code that runs with write permission: what they run and trust is pinned, and a release
# publishes only files that were verified. Static checks on .github/workflows/*.yml (no YAML library:
# the files are plain enough to read as text), plus the one pin in pyproject.toml.
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$BIN")/.." && pwd)"
"$PY" -I - "$ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, '.github/workflows/*.yml')))
assert [os.path.basename(f) for f in files] == ['release.yml', 'test.yml'], files
text = {os.path.basename(f): open(f).read() for f in files}

# 1. Every action is pinned by a full commit sha with its version in a comment; no moving tag, no branch.
for name, t in text.items():
    uses = re.findall(r'^\s*(?:-\s+)?uses:\s*(\S+)(.*)$', t, re.M)
    assert uses, name
    for ref, rest in uses:
        if ref.startswith('./'):
            continue  # a workflow in this repository
        assert re.fullmatch(r'[\w.-]+/[\w./-]+@[0-9a-f]{40}', ref), (name, 'action not pinned to a full sha', ref)
        assert re.search(r'#\s*v\d+\.\d+\.\d+', rest), (name, 'pin lacks a version comment', ref)

# 2. The tools are pinned to exact versions too.
assert re.search(r'^requires = \["hatchling==\d+\.\d+\.\d+"\]', open(os.path.join(root, 'pyproject.toml')).read(), re.M), 'hatchling must be pinned exactly'
for name, t in text.items():
    for m in re.finditer(r'astral-sh/setup-uv@\S+[^\n]*\n(?:\s+with:\n(?:\s+\S[^\n]*\n)*)?', t):
        assert re.search(r'version:\s*"?\d+\.\d+\.\d+"?', m.group(0)), (name, 'setup-uv needs an exact uv version', m.group(0))

rel = text['release.yml']
# 3. Jobs, and who may write: contents: write only in publish; id-token only where it is used.
jobs = re.split(r'(?m)^  (?=[a-z_]+:\n)', rel.split('\njobs:\n', 1)[1])
by = {j.split(':', 1)[0]: j for j in jobs if j.strip()}
assert {'check', 'test', 'build', 'publish', 'pypi', 'verify_published'} <= set(by), sorted(by)
for name, j in by.items():
    writes = 'contents: write' in j
    assert writes == (name == 'publish'), (name, 'contents: write belongs to publish only')
assert 'id-token: write' in by['pypi'] and 'attestations: write' in by['publish'] and 'id-token: write' in by['publish']

# 4. One build, verified, then those exact files are published and re-checked against recorded hashes.
assert 'uv build' in by['build'] and 'uv build' not in ''.join(by[n] for n in by if n != 'build'), 'build once, in the build job'
assert 'scripts/verify_dist.sh' in by['build'] and 'SHA256SUMS' in by['build'], 'the build job verifies the files and records sha256s'
for n in ('publish', 'pypi'):
    assert 'scripts/check_sums.sh dist expected-sums' in by[n], (n, 'must check the exact file set, the bytes and SHA256SUMS against the sums the build job emitted')
    assert 'actions/checkout' in by[n], (n, 'needs the repository for scripts/check_sums.sh')
assert '--verify-tag' in by['publish'], 'gh release create --verify-tag'
assert 'GITHUB_SHA' in by['publish'], 'the tag must still point at the built commit before the release is created'
assert 'actions/attest-build-provenance' in by['publish'], 'GitHub artifact attestations for the release assets'
assert re.search(r'attestations:\s*true', by['pypi']), 'PyPI attestations are explicit'
assert "vars.PUBLISH_PYPI == 'true'" in by['pypi']
assert '--sums expected-sums' in by['verify_published'] and 'scripts/verify_published.sh' in by['verify_published']
# The sums travel as a job output the build job emitted, not only inside the artifact they vouch for.
assert re.search(r'outputs:\s*\n\s+sums:\s*\$\{\{\s*steps\.\w+\.outputs\.sums\s*\}\}', by['build']), 'the build job must output the sums'
for n in ('publish', 'pypi', 'verify_published'):
    assert 'needs.build.outputs.sums' in by[n], (n, 'must check against the sums the build job emitted')
    assert re.search(r'needs:.*\bbuild\b', by[n].split('steps:')[0]) or n == 'verify_published', (n, 'needs build')
assert re.search(r'needs:\s*\[[^\]]*\bbuild\b', by['verify_published'].split('steps:')[0])
assert 'scripts/release_check.py --tag' in by['check'] and 'fetch-depth: 0' in by['check'], 'release_check needs history to prove the tag is on main'
# 5. Only final vX.Y.Z and vX.Y.ZrcN tags; a and b never.
assert re.search(r'\(rc\[0-9\]\+\)\?', rel) or re.search(r'rc\[0-9\]\+', rel), 'the tag shape check is missing'
assert '--prerelease' in by['publish']

# 6. test.yml: the embedded-skill check runs on pull requests too, and no skip is silently allowed in release.
t = text['test.yml']
assert 'embed_skill.py --check' in t and "refs/heads/main" not in t, 'the embedded skill check must not be limited to main'
assert '--allow-skip' not in rel and '--quick' not in rel, 'a release cannot allow skipped steps or leave out the nested tests'
print('workflows ok')
PY
ok "actions are sha-pinned, tools are pinned, one verified build is what gets published"
echo
echo "All workflow tests passed"
