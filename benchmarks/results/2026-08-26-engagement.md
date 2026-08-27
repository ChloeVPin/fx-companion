# 2026-08-26 — Production-path engagement

Environment: Apple M2, macOS 27.0, Darwin 27.0.0 arm64, Zig 0.16.0.
Pinned fx: `8d6152de17905429ad78decdb475df8cfd04f557`.
No model request.

Probe: `product/engagement_probe.zig` compiled in an injected fx tree as
`src/fx_companion_engagement.zig`.

```sh
python3 product/inject_hook.py /path/to/fx
cp product/engagement_probe.zig fx/src/fx_companion_engagement.zig
zig build-exe src/fx_companion_engagement.zig -lc -OReleaseFast -femit-bin=/tmp/engagement-probe
/tmp/engagement-probe /path/to/tree
```

## Phase 1 — before git-list cache

Companion hooked only sorted recursive `walkWorkspacePaths`. Production
`discover()` uses `git ls-files` first.

| Tree | git? | prod discover | companion | notes |
|---|---|---|---|---|
| fx-companion repo | yes | source=git 9–21 ms | skipped:git-primary (100%) | 43 tracked files |
| /tmp/fxanchor-new | no | source=recursive unsorted 462 ms then 60 ms | skipped:unsorted | 100k cap truncated |
| /opt/homebrew | yes | source=git 9–13 ms | skipped:git-primary (100%) | 3130 tracked files |

Recursive `force_fallback+sorted` on this repo was 0.52 ms cold / 0.027 ms warm
— faster than git, but production never takes that path in a git workspace.
`/opt/homebrew` recursive fallback truncated at 100k in 1279 ms; git listed
the real 3130 files in 13 ms. Git is the correct live path.

No grep or model timings. Discovery on these git trees is 9–21 ms, not 2 ms.

## Phase 2 — git ls-files snapshot

Additive cache: exec git on miss; snapshot parsed paths keyed by
`.git` directory / `HEAD` / `index` stamps. `--others` / untracked modes
are not cached. Never parses git objects.

Stock vs boosted (same process, `companion_enabled` false then true):

```text
# this repo, 100000 cap, --mutation-check
[files/git-primary-cold] IDENTICAL paths=43 stock=8617us boosted=8862us
[files/git-primary-warm] IDENTICAL paths=43 stock=8681us boosted=19us
[files/git-primary-after-untracked-create] IDENTICAL paths=43 stock=8371us boosted=22us
[files/git-primary-after-untracked-write] IDENTICAL paths=43 stock=7991us boosted=19us
[files/git-primary-after-untracked-delete] IDENTICAL paths=43 stock=8551us boosted=26us
EQUIVALENCE_OK cases=17

# /opt/homebrew, 600000 cap
[files/git-primary-cold] IDENTICAL paths=3130 stock=9900us boosted=9442us
[files/git-primary-warm] IDENTICAL paths=3130 stock=9153us boosted=24us
EQUIVALENCE_OK cases=9
```

Untracked create/write/delete stay warm: cache key is git identity, not the
worktree. Recursive tiny+mutation still `EQUIVALENCE_OK`.

Throwaway git repo (`verifyGitIdentityMutations`):

```text
[files/git-id-cold] IDENTICAL paths=1 stock=9599us boosted=9214us
[files/git-id-warm] IDENTICAL paths=1 stock=9657us boosted=18us
[files/git-id-after-tracked-content] IDENTICAL paths=1 stock=7690us boosted=15us
[files/git-id-after-untracked-file] IDENTICAL paths=1 stock=7689us boosted=14us
[files/git-id-include-untracked] IDENTICAL paths=2 stock=8089us boosted=8402us
[files/git-id-only-untracked] IDENTICAL paths=1 stock=8401us boosted=8252us
[files/git-id-after-index-add] IDENTICAL paths=2 stock=7901us boosted=7763us
[files/git-id-after-index-add-warm] IDENTICAL paths=2 stock=9751us boosted=19us
[files/git-id-after-branch] IDENTICAL paths=2 stock=8440us boosted=7885us
EQUIVALENCE_OK cases=23
```

Tracked content-only stays warm. `include_untracked` / `only_untracked` exec git
(2 paths / 1 path) instead of serving the tracked snapshot. `git add` and
branch checkout miss.

Synthetic 409k tree has no `.git`; production discover stays recursive.
Sorted fallback warm remains ~1.05 ms for the 100k cap.

## Phase 3 / 4

Not entered as extra walker work. Recursive equivalence matrix still
`EQUIVALENCE_OK cases=12` after the git-list hook. Grep/`@` picker were not
shown to dwarf 14 ms git discovery; no grep cache was added.

## `/profile`

On this git repo, `/profile` (via `product/profile_run.zig`) prints production
discover first:

```text
fx-companion engagement (production discover)
  source        git
  companion     cold=miss warm=hit (hit)
  paths         cold=43 warm=43
  git_list_ns   cold=29357542 warm=35125 (29.358 ms / 0.035 ms)
  no_model_request true
```

Then the recursive walk profile, labeled as not git ls-files.

## Binary size

Same pin, ReleaseFast stripped:

| | bytes |
|---|---:|
| stock fx | 11,787,440 |
| boosted fx | 11,888,464 |
| delta | +101,024 (0.096 MiB) |

Under the 1.0 MiB budget. Git-list warm-path win is measured.

## Recursive CI gate (after git-list hook)

1024×100 tree, cap 100k: correctness PASS, no `boosted LOST`.
median stock 79.557 ms, boosted warm 1.195 ms (66.59×).
