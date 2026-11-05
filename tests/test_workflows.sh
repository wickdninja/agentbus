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
assert [os.path.basename(f) for f in files] == ['release-dry-run.yml', 'release.yml', 'test.yml'], files
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

# 1b. Checkouts keep no credentials (nothing here pushes), and no job caches (a cache is a way into a release build).
for name, t_ in text.items():
    for m in re.finditer(r'actions/checkout@\S+[^\n]*\n((?: {8,}\S[^\n]*\n)*)', t_):
        assert 'persist-credentials: false' in m.group(1), (name, 'checkout must set persist-credentials: false')
    for m in re.finditer(r'astral-sh/setup-uv@\S+[^\n]*\n((?: {8,}\S[^\n]*\n)*)', t_):
        assert 'enable-cache: false' in m.group(1), (name, 'setup-uv must set enable-cache: false')
    assert 'cache:' not in t_.replace('enable-cache:', ''), (name, 'no actions cache')

rel = text['release.yml']
# 3. Jobs, and who may write: contents: write only in publish; id-token only where it is used.
jobs = re.split(r'(?m)^  (?=[a-z_]+:\n)', rel.split('\njobs:\n', 1)[1])
by = {j.split(':', 1)[0]: j for j in jobs if j.strip()}
assert set(by) == {'check', 'test', 'build', 'publish', 'verify_published'}, ('GitHub Releases is the only channel: no pypi job', sorted(by))
for name, j in by.items():
    writes = 'contents: write' in j
    assert writes == (name == 'publish'), (name, 'contents: write belongs to publish only')
assert 'attestations: write' in by['publish'] and 'id-token: write' in by['publish']
assert not re.search(r'(?i)pypi', rel.replace('(the name agentbus on PyPI belongs to an unrelated project)', '')), 'release.yml must not publish to or check PyPI'

# 4. One build, verified, then those exact files are published and re-checked against recorded hashes.
assert 'uv build' in by['build'] and 'uv build' not in ''.join(by[n] for n in by if n != 'build'), 'build once, in the build job'
assert 'scripts/verify_dist.sh' in by['build'] and 'SHA256SUMS' in by['build'], 'the build job verifies the files and records sha256s'
for n in ('publish',):
    assert 'scripts/check_sums.sh dist expected-sums' in by[n], (n, 'must check the exact file set, the bytes and SHA256SUMS against the sums the build job emitted')
    assert 'actions/checkout' in by[n], (n, 'needs the repository for scripts/check_sums.sh')
    # upload-artifact keeps paths relative to the files' common folder: dist/ and notes.md are uploaded together, so the
    # download holds dist/ already. A step that makes dist/ fails there (v0.2.0's first publish).
    assert 'mkdir dist' not in by[n] and 'mv *.whl' not in by[n], (n, 'the downloaded artifact already holds dist/')
    assert 'notes.md' in by['build'] and 'dist/*.whl' in by['build'], ('build', 'the artifact layout publish relies on')
# The attested files: the wheel, the sdist and SHA256SUMS (docs state the `gh attestation verify` command for them).
att = re.search(r'attest-build-provenance@\S+[^\n]*\n\s+with:\n\s+subject-path: \|\n((?: {8,}\S[^\n]*\n)*)', by['publish']).group(1).split()
assert att == ['dist/*.whl', 'dist/*.tar.gz', 'dist/SHA256SUMS'], att
# The dry run rehearses the publish job's file handling: the same upload block, then the download and check_sums.
dry = text['release-dry-run.yml']
def block(s):
    return re.search(r'actions/upload-artifact@\S+[^\n]*\n((?: {8,}\S[^\n]*\n)*)', s).group(1)
assert block(dry) == block(rel), 'release-dry-run.yml must upload the same artifact as release.yml'
assert 'scripts/check_sums.sh dist expected-sums' in dry and 'actions/download-artifact' in dry
assert 'workflow_dispatch' in dry and 'contents: write' not in dry and 'gh release' not in dry
# 1c. The static job and Dependabot.
assert re.search(r'(?m)^  static:', text['test.yml']) and all(x in text['test.yml'] for x in ('ruff@', 'shellcheck-py==', 'zizmor@')), 'test.yml needs the static job with pinned tools'
dep = open(os.path.join(root, '.github/dependabot.yml')).read()
assert 'package-ecosystem: github-actions' in dep and 'interval: weekly' in dep and 'groups:' in dep, 'dependabot.yml'
assert '--verify-tag' in by['publish'], 'gh release create --verify-tag'
assert 'GITHUB_SHA' in by['publish'], 'the tag must still point at the built commit before the release is created'
assert 'actions/attest-build-provenance' in by['publish'], 'GitHub artifact attestations for the release assets'
assert '--sums expected-sums' in by['verify_published'] and 'scripts/verify_published.sh' in by['verify_published']
# The sums travel as a job output the build job emitted, not only inside the artifact they vouch for.
assert re.search(r'outputs:\s*\n\s+sums:\s*\$\{\{\s*steps\.\w+\.outputs\.sums\s*\}\}', by['build']), 'the build job must output the sums'
for n in ('publish', 'verify_published'):
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
