#!/bin/zsh -f
# Bazel workspace status (see .bazelrc): the source commit stamped into the app's Info.plist as BBSourceCommit,
# so logs and diagnostics tell exactly which code a build came from. "-dirty" marks uncommitted changes.
# Release builds run from an exported tree without .git and pass the commit in BB_SOURCE_COMMIT.
if [[ -n ${BB_SOURCE_COMMIT:-} ]]; then
    commit=$BB_SOURCE_COMMIT
elif commit=$(git rev-parse --short=10 HEAD 2>/dev/null); then
    git diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
else
    commit=unknown
fi
print "STABLE_BB_SOURCE_COMMIT $commit"
