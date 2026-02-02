# fd compat harness (experimental)

This is a small tool to *extract* a curated subset of `fd`'s own integration
tests (typically from `../fd/tests/tests.rs`) and run them against `f` by translating
`fd` arguments into an equivalent `f` invocation.

It is intentionally narrow: it focuses on cases that fit the fixture tree under
`tests/fixtures/fd_default/` and skips tests that depend on symlinks, mtimes,
permissions, etc.

## Run

```sh
bash tests/fd_compat/run.sh run
```

## Extract JSONL

```sh
bash tests/fd_compat/run.sh extract --out /tmp/fd_cases.jsonl
```

## Allowlist

By default, `tests/fd_compat/allowlist.txt` controls which `fn test_*` blocks are
considered. You can override it with:

```sh
bash tests/fd_compat/run.sh run --functions @tests/fd_compat/allowlist.txt
```

