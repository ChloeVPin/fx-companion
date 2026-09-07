## What changed

Describe the change and why it is needed.

## Product impact

- [ ] No production behavior changes
- [ ] Production behavior changes are covered by stock-vs-companion differential validation
- [ ] `FX_NO_COMPANION=1` still preserves the stock escape hatch
- [ ] No unrelated `fx` executable or `~/.fx` user data is modified

## Validation

List the exact commands and results you ran. Include representative correctness and performance output when relevant.

## Upstream compatibility

If this touches the injection seam or upstream-facing behavior, provide the `PINNED_FX` commit and any newer upstream commit tested.

## Performance claims

If this changes performance, include hardware, macOS version, Zig version, workload shape, cap, cold/warm medians, and correctness results.

## Checklist

- [ ] The change is focused and reviewable
- [ ] New behavior has tests or a clear reason why tests are not applicable
- [ ] Documentation is updated when user-facing behavior changes
- [ ] I did not include secrets, private repository data, or sensitive logs
