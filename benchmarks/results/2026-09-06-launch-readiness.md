# 2026-09-06 - Launch-readiness verification

Environment: Apple M2 (`Mac14,2`, 8 cores, 8 GiB RAM), macOS 27.0 build
`26A5425a`, arm64, Zig 0.16.0. Pinned `fx`:
`8d6152de17905429ad78decdb475df8cfd04f557`.

## Installer

`node product/cli_smoke_test.js` passed against a local HTTP fixture covering:

- checksum-verified release download and extraction;
- rejection of an invalid boosted binary;
- preservation of an existing stock executable after failed validation;
- retirement of the stock executable only after successful installation;
- no-release source-fallback selection.

The fixture is deterministic and does not claim that a local fake binary is an
upstream `fx` build. The release workflow separately builds and equivalence-tests
the pinned upstream source.

## Cross-process Git cache

Using the pinned upstream checkout with 793 tracked paths, the new process-level
probe reported seven cold/disk pairs:

```text
cold ms: 22.223, 13.949, 12.518, 11.463, 10.511, 12.790, 10.977
disk  ms: 0.094, 0.078, 0.066, 0.070, 0.073, 0.080, 0.073
```

Untracked-file creation remained a cache hit. Staging a new tracked file caused
a miss, after which the next process reused the rebuilt snapshot.

## Recursive discovery baseline

Before the Git persistence change, the same 102,400-file APFS fixture measured:

```text
stock median: 79.436 ms
cold median:  86.004 ms
warm median:   1.021 ms
correctness: byte-identical
```

A post-change run remained byte-identical with `stock=85.940 ms`,
`cold=93.907 ms`, and `warm=1.185 ms`. A subsequent run was materially noisier
(`stock=338.797 ms`, `cold=341.873 ms`, `warm=2.174 ms`), so these samples do
not establish a universal regression or improvement. The persisted Git cache
does not execute on the forced recursive benchmark path. Re-run on a controlled
machine before making a new throughput claim.
