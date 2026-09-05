# fx-companion

An unofficial Apple Silicon companion for [fx](https://github.com/antonmedv/fx). It caches file-list and sorted-walk work for repeated runs while preserving the output contract of the stock command.

## Install

The npm package exposes an installer entry point:

```sh
npx github:ChloeVPin/fx-companion
```

Review the installer before running it. It targets macOS on Apple Silicon and requires Node.js 18 or newer.

## What it does

Git workspaces use the tracked path list from git ls-files. Other trees use a sorted filesystem walk. The companion keeps a snapshot and invalidates it when the relevant repository or path state changes.

The repository also contains a Zig daemon, clients, and traversal benchmarks. These are separate from the npm installer.

## Development

```sh
zig build test
zig build bench
```

The package is unofficial and is not affiliated with the fx project.

## License

Apache-2.0. See package.json.
