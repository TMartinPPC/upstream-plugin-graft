#!/bin/bash
# Automated tests for the upstream-plugin-graft CLI.
#
# Everything runs in a throwaway directory against fixture git repos, with
# gum, gh and omarchy-shell stubbed so the suite is offline and
# deterministic. gum reads its scripted answers from $FAKE_GUM_QUEUE
# (one token per line: a menu line index, "*" for the last entry, and for
# confirm/input the answers come from FAKE_GUM_CONFIRM / FAKE_GUM_INPUT).
# gh answers repo queries from canned files in $FAKE_GH_DIR.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/graft-test.XXXXXX")"
export OMARCHY_PLUGINS_DIR="$WORK/plugins"
mkdir -p "$OMARCHY_PLUGINS_DIR" "$WORK/stubs" "$WORK/gh"

pass=0
failed=0
ok() { pass=$((pass + 1)); echo "  ok  - $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL - $1"; }
check_eq() { # description expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---- stubs ---------------------------------------------------------------

cat >"$WORK/stubs/gum" <<'STUB'
#!/bin/bash
case "$1" in
choose)
  mapfile -t lines
  if [[ -n ${FAKE_GUM_QUEUE:-} && -s $FAKE_GUM_QUEUE ]]; then
    tok=$(head -n1 "$FAKE_GUM_QUEUE")
    sed -i '1d' "$FAKE_GUM_QUEUE"
    if [[ $tok == "*" ]]; then
      echo "${lines[${#lines[@]} - 1]}"
    else
      echo "${lines[$tok]}"
    fi
  else
    echo "${lines[0]}"
  fi
  ;;
confirm)
  [[ ${FAKE_GUM_CONFIRM:-yes} == yes ]] && exit 0 || exit 1
  ;;
input)
  echo "${FAKE_GUM_INPUT:-}"
  ;;
esac
STUB

cat >"$WORK/stubs/gh" <<'STUB'
#!/bin/bash
[[ $1 == auth ]] && exit 0
if [[ "$1 $2" == "api repos/"* ]]; then
  repo="${2#repos/}"
  f="$FAKE_GH_DIR/${repo//\//_}"
  if [[ -f $f ]]; then cat "$f"; else printf '0\t'; fi
  exit 0
fi
exit 1
STUB

cat >"$WORK/stubs/omarchy-shell" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$WORK/stubs"/*
export PATH="$WORK/stubs:$PATH"
export FAKE_GH_DIR="$WORK/gh"

DIVERGED="$ROOT/bin/omarchy-plugin-diverged"
GRAFT="$ROOT/bin/omarchy-plugin-graft"
FORK="$ROOT/bin/omarchy-plugin-fork"

# ---- fixture helpers ------------------------------------------------------

make_plugin_origin() { # $1 origin basename, $2 manifest id
  git init -q --bare -b main "$WORK/$1.git"
  git init -q -b main "$WORK/seed-$1"
  (
    cd "$WORK/seed-$1"
    git config user.email t@t
    git config user.name T
    mkdir -p sub
    cat >manifest.json <<EOF
{"schemaVersion":1,"id":"$2","name":"T","version":"1.0.0","author":"a","license":"MIT","description":"d","kinds":["service"],"entryPoints":{"service":"sub/Service.qml"}}
EOF
    echo base >sub/Service.qml
    git add .
    git commit -qm base
    git push -q "$WORK/$1.git" main
  )
  rm -rf "$WORK/seed-$1"
}

clone_plugin() { # $1 origin basename, $2 plugin id
  git clone -q "$WORK/$1.git" "$OMARCHY_PLUGINS_DIR/$2"
  git -C "$OMARCHY_PLUGINS_DIR/$2" config user.email t@t
  git -C "$OMARCHY_PLUGINS_DIR/$2" config user.name T
}

ahead_commits() { # $1 plugin dir, $2 count, $3 message prefix
  local d="$1" n="$2" p="$3" i
  for ((i = 1; i <= n; i++)); do
    echo "$p-$i" >>"$d/sub/extra.txt"
    git -C "$d" add .
    git -C "$d" commit -qm "$p $i"
  done
}

upstream_commit() { # $1 origin basename, $2 message, $3 Service.qml content
  rm -rf "$WORK/tmpclone"
  git clone -q "$WORK/$1.git" "$WORK/tmpclone"
  (
    cd "$WORK/tmpclone"
    git config user.email t@t
    git config user.name T
    echo "$3" >sub/Service.qml
    git add .
    git commit -qm "$2"
    git push -q origin main
  )
  rm -rf "$WORK/tmpclone"
}

# ---- diverged --------------------------------------------------------------

echo "== diverged: survey =="
make_plugin_origin p1 test.one
clone_plugin p1 test.one
ahead_commits "$OMARCHY_PLUGINS_DIR/test.one" 2 local

out=$("$DIVERGED" --json test.one)
check_eq "diverged exit 0 when diverged" 0 "$?"
check_eq "json ahead count" 2 "$(jq -r '.[0].ahead' <<<"$out")"
check_eq "json dirty flag" false "$(jq -r '.[0].dirty' <<<"$out")"
check_eq "json rebase flag" false "$(jq -r '.[0].rebaseInProgress' <<<"$out")"
check_eq "json upstream ref" refs/remotes/origin/HEAD "$(jq -r '.[0].upstream' <<<"$out")"

"$DIVERGED" test.one >/dev/null
check_eq "text exit 0 when diverged" 0 "$?"

touch "$OMARCHY_PLUGINS_DIR/test.one/stray"
out=$("$DIVERGED" --json test.one)
check_eq "dirty flag on untracked file" true "$(jq -r '.[0].dirty' <<<"$out")"
rm "$OMARCHY_PLUGINS_DIR/test.one/stray"

make_plugin_origin p2 test.two
clone_plugin p2 test.two
out=$("$DIVERGED" --json test.two)
check_eq "clean plugin json is empty" "[]" "$out"
"$DIVERGED" test.two >/dev/null
check_eq "clean plugin exit 1" 1 "$?"

mkdir -p "$OMARCHY_PLUGINS_DIR/test.one/.git/rebase-merge"
out=$("$DIVERGED" --json test.one)
check_eq "mid-rebase detected" true "$(jq -r '.[0].rebaseInProgress' <<<"$out")"
rmdir "$OMARCHY_PLUGINS_DIR/test.one/.git/rebase-merge"

make_plugin_origin p3 test.three
clone_plugin p3 test.three
ahead_commits "$OMARCHY_PLUGINS_DIR/test.three" 1 local
git -C "$OMARCHY_PLUGINS_DIR/test.three" remote remove origin
touch "$OMARCHY_PLUGINS_DIR/test.three/stray"
out=$("$DIVERGED" --json test.three)
check_eq "unknown upstream reported" unknown "$(jq -r '.[0].upstream' <<<"$out")"
rm "$OMARCHY_PLUGINS_DIR/test.three/stray"

"$DIVERGED" nope.plugin >/dev/null 2>&1
check_eq "unknown plugin id exit 2" 2 "$?"

# ---- graft -----------------------------------------------------------------

echo "== graft: fast-forward =="
make_plugin_origin p4 test.four
clone_plugin p4 test.four
upstream_commit p4 "upstream adds file" upstream-change
"$GRAFT" test.four --yes >/dev/null
check_eq "ff graft exit 0" 0 "$?"
check_eq "ff graft moved to upstream tip" "upstream adds file" "$(git -C "$OMARCHY_PLUGINS_DIR/test.four" log -1 --format=%s)"
"$DIVERGED" test.four >/dev/null
check_eq "clean after ff (tracking ref recorded)" 1 "$?"

echo "== graft: rebase replay =="
make_plugin_origin p5 test.five
clone_plugin p5 test.five
ahead_commits "$OMARCHY_PLUGINS_DIR/test.five" 2 local
upstream_commit p5 "upstream adds file" upstream-line
"$GRAFT" test.five --yes >/dev/null
gout=$("$GRAFT" test.five --yes 2>&1)
check_eq "rebase graft exit 0" 0 "$?"
check_eq "done summary counts upstream + kept" yes \
  "$(grep -qE 'graft done for test\.five: 1 upstream commit integrated; 2 local commits kept on top' <<<"$gout" && echo yes)"
check_eq "history order: upstream below local" \
  "local 2
local 1
upstream adds file" \
  "$(git -C "$OMARCHY_PLUGINS_DIR/test.five" log --format=%s -3)"
check_eq "local file content kept" "local-1
local-2" "$(tail -n2 "$OMARCHY_PLUGINS_DIR/test.five/sub/extra.txt")"
check_eq "upstream file content merged" "upstream-line" "$(cat "$OMARCHY_PLUGINS_DIR/test.five/sub/Service.qml")"
# After a graft the local commits remain (by design), so the survey keeps
# flagging the plugin: what must clear is the rebase/dirty state and the
# stale upstream tip.
out=$("$DIVERGED" --json test.five)
check_eq "post-rebase survey exit 0 (local commits remain)" 0 "$?"
check_eq "post-rebase ahead is local count" 2 "$(jq -r '.[0].ahead' <<<"$out")"
check_eq "post-rebase rebase cleared" false "$(jq -r '.[0].rebaseInProgress' <<<"$out")"
check_eq "post-rebase clean tree" false "$(jq -r '.[0].dirty' <<<"$out")"

echo "== graft: conflict pause and resume =="
make_plugin_origin p6 test.six
clone_plugin p6 test.six
# Local commit must touch the same file AND content as upstream to conflict.
echo local-way >"$OMARCHY_PLUGINS_DIR/test.six/sub/Service.qml"
git -C "$OMARCHY_PLUGINS_DIR/test.six" add sub/Service.qml
git -C "$OMARCHY_PLUGINS_DIR/test.six" commit -qm "local edits service"
upstream_commit p6 "upstream edits service" rewritten
"$GRAFT" test.six --yes >/dev/null 2>&1
check_eq "conflict graft exits 1" 1 "$?"
out=$("$DIVERGED" --json test.six)
check_eq "paused rebase flagged in survey" true "$(jq -r '.[0].rebaseInProgress' <<<"$out")"
echo both >"$OMARCHY_PLUGINS_DIR/test.six/sub/Service.qml"
git -C "$OMARCHY_PLUGINS_DIR/test.six" add sub/Service.qml
"$GRAFT" test.six --yes >/dev/null
check_eq "resume exits 0" 0 "$?"
check_eq "conflict resolution kept" "both" "$(cat "$OMARCHY_PLUGINS_DIR/test.six/sub/Service.qml")"
out=$("$DIVERGED" --json test.six)
check_eq "post-resume rebase cleared" false "$(jq -r '.[0].rebaseInProgress' <<<"$out")"

echo "== graft: dirty tree refusal =="
make_plugin_origin p7 test.seven
clone_plugin p7 test.seven
ahead_commits "$OMARCHY_PLUGINS_DIR/test.seven" 1 local
touch "$OMARCHY_PLUGINS_DIR/test.seven/stray"
"$GRAFT" test.seven --yes >/dev/null 2>&1
check_eq "dirty tree refused" 1 "$?"
check_eq "HEAD untouched by refusal" "local 1" "$(git -C "$OMARCHY_PLUGINS_DIR/test.seven" log -1 --format=%s)"
rm "$OMARCHY_PLUGINS_DIR/test.seven/stray"

echo "== graft: rollback when result fails validation =="
make_plugin_origin p8 test.eight
clone_plugin p8 test.eight
rm -rf "$WORK/tmpclone"
git clone -q "$WORK/p8.git" "$WORK/tmpclone"
(
  cd "$WORK/tmpclone"
  git config user.email t@t
  git config user.name T
  git rm -q manifest.json
  git commit -qm "upstream breaks the plugin"
  git push -q origin main
)
rm -rf "$WORK/tmpclone"
"$GRAFT" test.eight --yes >/dev/null 2>&1
check_eq "failed validation exits 1" 1 "$?"
check_eq "rolled back to pre-graft commit" "base" "$(git -C "$OMARCHY_PLUGINS_DIR/test.eight" log -1 --format=%s)"
check_eq "manifest restored by rollback" yes "$([[ -f $OMARCHY_PLUGINS_DIR/test.eight/manifest.json ]] && echo yes)"

echo "== graft: reroute through upstream remote =="
# With an upstream remote, graft must follow the creator even if origin is
# broken (or is a stale fork): proven by pointing origin at a nonexistent
# path and having upstream carry the new commit.
make_plugin_origin p11 reroute-plugin
clone_plugin p11 reroute-plugin
ahead_commits "$OMARCHY_PLUGINS_DIR/reroute-plugin" 1 local
git -C "$OMARCHY_PLUGINS_DIR/reroute-plugin" remote set-url origin /nonexistent-repo
git -C "$OMARCHY_PLUGINS_DIR/reroute-plugin" remote add upstream "$WORK/p11.git"
upstream_commit p11 "creator update" creator-line
"$GRAFT" reroute-plugin --yes >/dev/null
check_eq "reroute graft exit 0" 0 "$?"
check_eq "reroute kept local commit on top" "local 1" "$(git -C "$OMARCHY_PLUGINS_DIR/reroute-plugin" log -1 --format=%s)"
check_eq "reroute integrated creator commit" "creator-line" "$(cat "$OMARCHY_PLUGINS_DIR/reroute-plugin/sub/Service.qml")"

echo "== graft: --all over several plugins =="
# Isolated dir: --all processes every git plugin, and the main fixture zoo
# deliberately contains broken ones (rolled-back manifest, missing origin),
# so a whole-zoo --all legitimately exits 1.
make_plugin_origin p9 test.nine
make_plugin_origin pa test.ten
W3="$WORK/plugins-w3"
mkdir -p "$W3"
export OMARCHY_PLUGINS_DIR="$W3"
git clone -q "$WORK/p9.git" "$W3/test.nine"
git -C "$W3/test.nine" config user.email t@t
git -C "$W3/test.nine" config user.name T
git clone -q "$WORK/pa.git" "$W3/test.ten"
git -C "$W3/test.ten" config user.email t@t
git -C "$W3/test.ten" config user.name T
ahead_commits "$W3/test.nine" 1 local
ahead_commits "$W3/test.ten" 1 local
upstream_commit p9 "upstream 9" upstream-9
upstream_commit pa "upstream 10" upstream-10
"$GRAFT" --all --yes >/dev/null
check_eq "graft --all exit 0" 0 "$?"
check_eq "plugin 9 grafted" "local 1" "$(git -C "$W3/test.nine" log -1 --format=%s)"
check_eq "plugin 10 grafted" "local 1" "$(git -C "$W3/test.ten" log -1 --format=%s)"
check_eq "plugin 9 has upstream too" "upstream 9" "$(git -C "$W3/test.nine" log --format=%s -2 | tail -1)"
export OMARCHY_PLUGINS_DIR="$WORK/plugins"

echo "== graft: interactive chooser (pseudo-tty) =="
# The chooser is the path the bar widget hits; regression test for the
# FETCH_HEAD bug that made it see zero diverged plugins. "*" picks the
# last menu entry ("ALL of the above").
if command -v script >/dev/null 2>&1; then
  export FAKE_GUM_QUEUE="$WORK/chooser-queue"
  echo "*" >"$FAKE_GUM_QUEUE"
  script -qec "$GRAFT" "$WORK/chooser-typescript" </dev/null >/dev/null
  tty_out="$(cat "$WORK/chooser-typescript")"
  check_eq "chooser saw diverged plugins (no empty-report message)" \
    yes "$(grep -q 'No plugins with local commits' <<<"$tty_out" && echo no || echo yes)"
  check_eq "chooser ran the grafts" yes "$(grep -qE 'up to date|graft done' <<<"$tty_out" && echo yes)"
  unset FAKE_GUM_QUEUE
else
  echo "  skip - script(1) unavailable"
fi

# ---- fork ------------------------------------------------------------------

echo "== fork: refusals =="
"$FORK" nope.plugin >/dev/null 2>&1
check_eq "unknown plugin refused" 1 "$?"
git -C "$OMARCHY_PLUGINS_DIR/test.nine" remote add upstream "$WORK/p9.git"
"$FORK" test.nine >/dev/null 2>&1
check_eq "already-forked plugin refused" 1 "$?"

echo "== fork: URL parser =="
eval "$(sed -n '/^github_repo_of_url()/,/^}/p' "$FORK")"
check_eq "https url" "TMartinPPC/plugin" "$(github_repo_of_url "https://github.com/TMartinPPC/plugin.git")"
check_eq "https url no suffix" "bjarneo/plugin" "$(github_repo_of_url "https://github.com/bjarneo/plugin")"
check_eq "ssh url" "bjarneo/plugin" "$(github_repo_of_url "git@github.com:bjarneo/plugin.git")"
check_eq "ssh:// url" "Somnius/Plugin" "$(github_repo_of_url "ssh://git@github.com/Somnius/Plugin")"
check_eq "non-github rejected" "" "$(github_repo_of_url "https://gitlab.com/foo/bar.git" 2>/dev/null || echo "")"

# Wizard tests run in an isolated plugins dir so menu indexes are stable
# and the fixture fixtures don't pollute the survey.
echo "== fork wizard: auto-detected GitHub fork =="
make_plugin_origin pb test.eleven
W1="$WORK/plugins-w1"
mkdir -p "$W1"
git clone -q "$WORK/pb.git" "$W1/test.eleven"
git -C "$W1/test.eleven" config user.email t@t
git -C "$W1/test.eleven" config user.name T
git -C "$W1/test.eleven" remote set-url origin "https://github.com/FakeUser/some-fork.git"
printf '1\trealcreator/real-plugin\n' >"$WORK/gh/FakeUser_some-fork"
export FAKE_GUM_QUEUE="$WORK/wizard-queue"
export OMARCHY_PLUGINS_DIR="$W1"
printf '0\n*\n' >"$FAKE_GUM_QUEUE"
"$FORK" --yes >/dev/null 2>&1
check_eq "wizard added auto-detected upstream" "https://github.com/realcreator/real-plugin.git" \
  "$(git -C "$W1/test.eleven" remote get-url upstream)"
# Populate the upstream ref from the local fixture so the survey check needs
# no network; the wizard itself tolerates a failed fetch. Plain fetch does
# not create the tracking HEAD symref — graft does that via update-ref, so
# mirror it with remote set-head.
git -C "$W1/test.eleven" remote set-url upstream "$WORK/pb.git"
git -C "$W1/test.eleven" fetch -q upstream
git -C "$W1/test.eleven" remote set-head upstream -a
ahead_commits "$W1/test.eleven" 1 local
out=$("$DIVERGED" --json test.eleven)
check_eq "upstream now resolves for graft" refs/remotes/upstream/HEAD "$(jq -r '.[0].upstream' <<<"$out")"
export OMARCHY_PLUGINS_DIR="$WORK/plugins"

echo "== fork wizard: manual URL entry =="
make_plugin_origin pc test.twelve
W2="$WORK/plugins-w2"
mkdir -p "$W2"
git clone -q "$WORK/pc.git" "$W2/test.twelve"
git -C "$W2/test.twelve" config user.email t@t
git -C "$W2/test.twelve" config user.name T
git -C "$W2/test.twelve" remote set-url origin "https://gitlab.com/creator/plugin.git"
export OMARCHY_PLUGINS_DIR="$W2"
printf '0\n*\n' >"$FAKE_GUM_QUEUE"
export FAKE_GUM_INPUT="https://github.com/manualcreator/manual-plugin"
"$FORK" --yes >/dev/null 2>&1
check_eq "wizard added manual upstream" "https://github.com/manualcreator/manual-plugin" \
  "$(git -C "$W2/test.twelve" remote get-url upstream)"
unset FAKE_GUM_INPUT FAKE_GUM_QUEUE OMARCHY_PLUGINS_DIR

# ---- summary ----------------------------------------------------------------

echo
echo "passed: $pass  failed: $failed"
[[ $failed == 0 ]]