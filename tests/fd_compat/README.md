# fd compat harness (experimental)

This is a small tool to *extract* a curated subset of `fd`'s own integration
tests (from `~/p/my/fd/tests/tests.rs`) and run them against `f` by translating
`fd` arguments into an equivalent `f` invocation.

It is intentionally narrow: it focuses on cases that fit the fixture tree under
`tests/fixtures/fd_default/` and skips tests that depend on symlinks, mtimes,
permissions, etc.

## Run

```sh
cargo run --manifest-path tests/fd_compat/Cargo.toml -- run
```

## Extract JSONL

```sh
cargo run --manifest-path tests/fd_compat/Cargo.toml -- extract --out /tmp/fd_cases.jsonl
```

