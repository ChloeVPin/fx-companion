# Homebrew packaging

The Homebrew distribution is intentionally keg-only.

There are already Homebrew formulae that provide an `fx` executable. A normal
linked formula could shadow or replace an unrelated installation, which would
violate fx-companion's safety contract. The formula template therefore requires
an explicit PATH opt-in.

The formula also wraps `fx upgrade`. Upstream `fx` updates itself by replacing
its current executable. That behavior is correct for an upstream-managed binary
but would mutate a Homebrew Cellar installation. In the Homebrew package,
`fx upgrade` instead tells the user to run `brew upgrade fx-companion`.

`Formula/fx-companion.rb.in` is a release template. Replace:

- `@VERSION@` with the fx-companion release version without the leading `v`
- `@ASSET_SHA256@` with the matching release archive SHA-256

The published tap should live in a separate `ChloeVPin/homebrew-fx-companion`
repository so users can install it with:

```sh
brew install ChloeVPin/fx-companion/fx-companion
```

Do not use `brew link --force` for this package.
