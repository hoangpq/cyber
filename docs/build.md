## Build
To get the maximum performance, you'll need to build Cyber from source.

## Dependencies
Get the latest Zig compiler (0.11.0-dev) [here](https://ziglang.org/download/).
If you use Zig often, you can use [zigup](https://github.com/marler8997/zigup) to manage different versions of the compiler.

Once you have zig installed, checkout the repo:
```sh
git clone https://github.com/fubark/cyber.git
```

## Run Tests
```sh
# Runs all tests.
zig build test

# Runs just the tracing tests.
zig build test-trace
```

## Build the CLI.
Cyber is optimized for the release-fast build.
```sh
zig build cli -Drelease-fast

# For a debug build instead.
zig build cli
```

## Troubleshooting.
- If you have trouble building mimalloc on MacOS, consider changing the sdk path in `lib/mimalloc/lib.zig` to your installed version.
