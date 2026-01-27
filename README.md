# f

An opinionated frontend for [fd](https://github.com/sharkdp/fd) that defaults
to searching everything — hidden files, ignored files, full paths — with
automatic wildcard wrapping. Think of it as fd tuned for interactive "find
anything" use, closer to the [Everything](https://www.voidtools.com/) mental
model.

`f` is not a reimplementation. All of fd's speed, parallelism, colored output,
and regex engine pass straight through. `f` just changes the defaults and adds
a few conveniences on top.

## How it differs from fd

| Behavior | fd | f |
|---|---|---|
| Hidden files | excluded | **included** (`-O` to hide) |
| Gitignore / .ignore | respected | **bypassed** (`-G` to respect) |
| Match target | basename | **full path** (`-n` for basename) |
| Case sensitivity | smart-case | **ignore-case** (`-C` for sensitive) |
| Pattern syntax | regex | **glob** (`-r` for regex, `-F` for fixed) |
| Wildcards | literal | **auto-wrapped**: `foo` → `*foo*` (`-w` to disable) |
| VCS metadata (.git, .svn, .hg) | visible with `--hidden` | **excluded** (`-V` to include) |

## Install

Copy `f` (bash) or `f.ps1` (PowerShell 7+) somewhere on your `PATH`.
Requires [fd](https://github.com/sharkdp/fd).

```sh
# Example
cp f ~/.local/bin/
```

## Quick examples

```sh
# Find anything containing "config" in the path
f config

# Only files, with extension .toml
f -f -e toml config

# Tail match — paths ending with "rc"
f -T rc

# Fixed string search (no glob/regex interpretation)
f -F '[weird]name'

# Regex mode
f -r '\.bak$'

# Files changed in the last hour, at least 1kb
f -A 1h -S +1k

# AND patterns — must match both
f -P test -P util

# Execute a command per match
f -e zip -x unzip

# Anything fd can do, via passthrough
f config -- --owner john
```

Note: if your pattern contains shell glob characters (`*`, `?`, `[]`), quote it
in shells like bash/zsh so it reaches `f` unchanged (example: `f '*.toml'`).

## Flags

```
Switches:
  -f  files only
  -d  directories only
  -b  executables (bin)
  -w  do not auto-wrap with wildcards
  -T  tail match (ends with)
  -G  respect Git/.ignore rules
  -O  hide dotfiles
  -r  use regex (default: glob)
  -F  use fixed strings (not regex/glob)
  -n  search only basenames
  -a  display absolute paths
  -C  case-sensitive
  -l  list path details (like ls -l)
  -L  follow symlinked directories
  -V  include VCS metadata (.git, .svn, .hg)
  -m  stay on one filesystem (mount)
  -N  hide empty files
  -Q  print only one result
  -z  NUL-delimited output
  -h  show help

Parameterized (repeatable where marked +):
  -D <depth>      max search depth
  -e <ext>        file extension (+)
  -t <type|help>  file type filter (+)
  -E <glob>       exclude pattern (+)
  -P <pat>        additional required pattern (+)
  -S <size|help>  size filter (+)
  -A <time|help>  changed after / within
  -B <time|help>  changed before / older than
  -x <cmd|help>   exec per match
  -X <cmd|help>   exec in batch
  -- <fd-args>    pass remaining args to fd
```

Pass `help` as the argument to `-t`, `-S`, `-x`, `-X`, `-A`, or `-B` for
format details.

## Environment variables

| Variable | Purpose |
|---|---|
| `F_FD_BIN` | Override fd binary path (default: auto-detect `fd` or `fdfind`) |
| `F_FD_DBG` | Set to `1` to print the generated fd command to stderr |

## License

MIT (see `LICENSE.txt`).
