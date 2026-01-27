#!/bin/bash
# f - fd wrapper with convenient defaults
# License: MIT — https://github.com/sharkdp/fd/blob/master/LICENSE-MIT

fd_dbg="${F_FD_DBG:-}"

if [ -n "${F_FD_BIN:-}" ]; then
    fd_bin="$F_FD_BIN"
else
    if command -v fd >/dev/null 2>&1; then
        fd_bin="fd"
    elif command -v fdfind >/dev/null 2>&1; then
        fd_bin="fdfind"
    else
        echo "error: fd binary not found (looked for: fd, fdfind; set F_FD_BIN=/path/to/fd)" >&2
        exit 127
    fi
fi

if [[ "$fd_bin" == */* ]]; then
    if [ ! -x "$fd_bin" ]; then
        echo "error: F_FD_BIN is not executable: $fd_bin" >&2
        exit 127
    fi
else
    if ! command -v "$fd_bin" >/dev/null 2>&1; then
        echo "error: fd binary not found: $fd_bin (set F_FD_BIN=/path/to/fd)" >&2
        exit 127
    fi
fi

run_fd() {
    local cmd=("$fd_bin" "$@")
    if [ "$fd_dbg" = "1" ]; then
        printf '%q ' "${cmd[@]}" >&2
        printf '\n' >&2
    fi
    "${cmd[@]}"
}

files_only=0
dirs_only=0
executable_type=0
respect_gitignore=0
respect_hidden=0
non_empty=0
# 0=*contains*/.*contains.* 1=no-add-wildcards 2=*tail/.*tail
match_mode=0
use_regex=0
basename_only=0
absolute_path=0
max_depth=""
max_results=""
print0=0
one_file_system=0
changed_within=""
changed_before=""
list_details=0
case_sensitive=0
fixed_strings=0
follow_links=0
show_vcs=0
extensions=()
types=()
exec_mode="" # "", "exec", "exec-batch"
exec_cmd=()
show_help=0

excludes=()
and_patterns=()
sizes=()

while getopts "zfdbOQNwTGrnalClLFVmx:X:t:D:E:P:e:A:B:S:h" opt; do
    case $opt in
        z) print0=1 ;;
        f) files_only=1 ;;
        d) dirs_only=1 ;;
        b) executable_type=1 ;;
        O) respect_hidden=1 ;;
        Q) max_results="1" ;;
        N) non_empty=1 ;;
        w) match_mode=1 ;;
        T) match_mode=2 ;;
        G) respect_gitignore=1 ;;
        C) case_sensitive=1 ;;
        r) use_regex=1 ;;
        n) basename_only=1 ;;
        a) absolute_path=1 ;;
        l) list_details=1 ;;
        L) follow_links=1 ;;
        F) fixed_strings=1 ;;
        V) show_vcs=1 ;;
        D) max_depth="$OPTARG" ;;
        E) excludes+=("$OPTARG") ;;
        P) and_patterns+=("$OPTARG") ;;
        e) extensions+=("$OPTARG") ;;
        A) changed_within="$OPTARG" ;;
        B) changed_before="$OPTARG" ;;
        S) sizes+=("$OPTARG") ;;
        t) types+=("$OPTARG") ;;
        m) one_file_system=1 ;;
        x) exec_mode="exec"; exec_cmd=("$OPTARG") ;;
        X) exec_mode="exec-batch"; exec_cmd=("$OPTARG") ;;
        h) show_help=1 ;;
        *) echo "Usage: f [options] [pattern] [path...]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ -n "$max_depth" ] && ! [[ "$max_depth" =~ ^[0-9]+$ ]]; then
    echo "error: -D expects a non-negative integer depth, got: $max_depth" >&2
    exit 2
fi

if [ $fixed_strings -eq 1 ] && [ $use_regex -eq 1 ]; then
    echo "error: -F (fixed strings) cannot be combined with -r (regex)" >&2
    exit 2
fi

if [ $fixed_strings -eq 1 ] && [ $match_mode -ne 0 ]; then
    echo "error: -F (fixed strings) cannot be combined with -w/-T match modes" >&2
    exit 2
fi

# Optional fd passthrough after '--'
passthru=()
if [ $# -gt 0 ]; then
    pos=("$@")
    for idx in "${!pos[@]}"; do
        if [ "${pos[$idx]}" = "--" ]; then
            passthru=("${pos[@]:$((idx+1))}")
            set -- "${pos[@]:0:$idx}"
            break
        fi
    done
fi

if [ "$changed_within" = "help" ] || [ "$changed_before" = "help" ]; then
    echo "Time formats (for -A/-B):"
    echo "  durations: 10h, 1d, 35min, 2weeks"
    echo "  dates:     'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', '@unix_timestamp'"
    exit 0
fi

for _sz in "${sizes[@]}"; do
    if [ "$_sz" = "help" ]; then
        echo "Size formats (for -S):"
        echo "  prefix: +  (at least)    -  (at most)    (none = exactly)"
        echo "  units:  b  k  m  g  t    (base-10)"
        echo "          ki mi gi ti      (base-2)"
        echo ""
        echo "  examples: +100k  -1m  4gi  +0b"
        echo "  -N is shorthand for -S +1b (non-empty)"
        exit 0
    fi
done

for _t in "${types[@]}"; do
    if [ "$_t" = "help" ]; then
        echo "File types (for -t):"
        echo "  f  file             d  directory"
        echo "  l  symlink          x  executable"
        echo "  e  empty            s  socket"
        echo "  p  pipe (FIFO)      b  block-device"
        echo "  c  char-device"
        echo ""
        echo "  Multiple types combine as OR. Comma-separated or repeated."
        echo "  -f/-d/-b are shorthand for -t f, -t d, -t x"
        exit 0
    fi
done

if [ "$exec_mode" = "exec" ] && [ "${exec_cmd[0]}" = "help" ]; then
    echo "Exec per match (-x <cmd>):"
    echo "  Runs <cmd> for each result (in parallel)."
    echo ""
    echo "  placeholders:"
    echo "    {}    path                {/}   basename"
    echo "    {//}  parent directory    {.}   path without extension"
    echo "    {/.}  basename without extension"
    echo "    {{    literal {           }}    literal }"
    echo ""
    echo "  If no placeholder is present, {} is appended implicitly."
    echo ""
    echo "  examples:"
    echo "    f -e zip -x unzip"
    echo "    f -e jpg -x convert {} {.}.png"
    exit 0
fi

if [ "$exec_mode" = "exec-batch" ] && [ "${exec_cmd[0]}" = "help" ]; then
    echo "Exec in batches (-X <cmd>):"
    echo "  Runs <cmd> once with all results as arguments."
    echo ""
    echo "  placeholders:"
    echo "    {}    path                {/}   basename"
    echo "    {//}  parent directory    {.}   path without extension"
    echo "    {/.}  basename without extension"
    echo "    {{    literal {           }}    literal }"
    echo ""
    echo "  If no placeholder is present, {} is appended implicitly."
    echo ""
    echo "  examples:"
    echo "    f -e py -X vim"
    echo "    f -e rs -X wc -l"
    exit 0
fi

if [ $show_help -eq 1 ]; then
    echo "Usage: f [options] [pattern] [path...]"
    echo ""
    echo "Switches:"
    echo "  -f  files"
    echo "  -d  directories"
    echo "  -b  executables (bin)"
    echo "  -w  do not surround with wildcards"
    echo "  -T  Tail match (ends with)"
    echo "  -G  respect Git/.ignore rules"
    echo "  -O  hide dOtfiles"
    echo "  -r  use regex (default: glob)"
    echo "  -F  use Fixed strings (not regex/glob)"
    echo "  -n  search only basenames"
    echo "  -a  display absolute paths"
    echo "  -C  Case-sensitive"
    echo "  -l  list path details (like ls -l)"
    echo "  -L  follow symLinked directories"
    echo "  -V  include Vcs metadata (.git, .svn, .hg)"
    echo "  -m  stay on one filesystem (mount)"
    echo "  -N  hide empty files"
    echo "  -Q  print only one result"
    echo "  -z  delimit results with NULs"
    echo "  -h  show this help"
    echo ""
    echo "Flags:"
    echo "  -D <depth>      max search Depth"
    echo "  -e <ext>        file extension +"
    echo "  -t <type|help>  file types (kinds) +"
    echo "  -E <glob>       Exclude +"
    echo "  -P <pat>        add required Pattern +"
    echo "  -S <size|help>  Size filter +"
    echo "  -A <time|help>  changed After (or within)"
    echo "  -B <time|help>  changed Before (older than)"
    echo "  -x <cmd|help>   exec for each match"
    echo "  -X <cmd|help>   eXec in batches"
    echo "  -- <fd-args>    forward <fd-args> to fd"
    echo "+ = indicates a repeatable flag"
    echo ""
    echo "Defaults differ from fd:"
    echo "  bypass ignore rules, search hidden, search pathnames,"
    echo "  ignore-case, glob (vs. regex), automatic wildcards,"
    echo "  exclude VCS metadata (.git, .svn, .hg)"
    echo ""
    exit 0
fi

# Build fd arguments
args=()
[ $case_sensitive -eq 1 ] && args+=(-s)
[ $case_sensitive -eq 0 ] && args+=(-i)

# Hidden/ignored defaults (include both unless flags set)
[ $respect_hidden -eq 0 ] && args+=(-H)
[ $respect_gitignore -eq 0 ] && args+=(-I)

# Follow links
[ $follow_links -eq 1 ] && args+=(-L)

# Output format
[ $print0 -eq 1 ] && args+=(--print0)
[ $list_details -eq 1 ] && args+=(--list-details)

# Full path vs basename
[ $basename_only -eq 0 ] && args+=(-p)

# Glob vs regex vs fixed strings
[ $fixed_strings -eq 1 ] && args+=(-F)
[ $fixed_strings -eq 0 ] && [ $use_regex -eq 0 ] && args+=(-g)

# Result limit
[ -n "$max_results" ] && args+=(--max-results "$max_results")

# Type filters (-f/-d/-b) and explicit types (-t) combine as OR filters.
[ $files_only -eq 1 ] && types+=("f")
[ $dirs_only -eq 1 ] && types+=("d")
[ $executable_type -eq 1 ] && types+=("x")
for t in "${types[@]}"; do
    IFS=',' read -r -a split_types <<<"$t"
    for st in "${split_types[@]}"; do
        [ -n "$st" ] && args+=(-t "$st")
    done
done

[ $absolute_path -eq 1 ] && args+=(-a)

# Size filters
[ $non_empty -eq 1 ] && args+=(-S+1b)
for sz in "${sizes[@]}"; do
    args+=(-S "$sz")
done

# Depth
[ -n "$max_depth" ] && args+=(--max-depth "$max_depth")

# Time filters
[ -n "$changed_within" ] && args+=(--changed-within "$changed_within")
[ -n "$changed_before" ] && args+=(--changed-before "$changed_before")

# Extension filters (-e) are repeatable.
for ext in "${extensions[@]}"; do
    args+=(-e "$ext")
done

# Exec options must come after [pattern] [path...] so fd doesn't treat them as part of <cmd>...
post_args=()
if [ -n "$exec_mode" ]; then
    if [ "$exec_mode" = "exec" ]; then
        post_args+=(-x "${exec_cmd[0]}")
    else
        post_args+=(-X "${exec_cmd[0]}")
    fi
fi

# Filesystem boundary
[ $one_file_system -eq 1 ] && args+=(--one-file-system)

# VCS metadata directories excluded by default; -V to include
if [ $show_vcs -eq 0 ]; then
    args+=(--exclude=.git --exclude=.svn --exclude=.hg)
fi

# Excludes (-E) are glob patterns (repeatable).
for ex in "${excludes[@]}"; do
    args+=(--exclude="$ex")
done

# No pattern provided: behave like `fd` with just the selected filters.
if [ $# -eq 0 ]; then
    run_fd "${args[@]}" "${passthru[@]}" "${post_args[@]}"
    exit $?
fi

pattern="$1"
shift
paths=("$@")

# Build pattern
if [ $fixed_strings -eq 1 ]; then
    search_pattern="$pattern"
elif [ $use_regex -eq 0 ]; then
    # Glob mode
    case $match_mode in
        1) search_pattern="**/$pattern" ;;
        2) search_pattern="**/*$pattern" ;;
        *) search_pattern="**/*$pattern*" ;;
    esac
else
    # Regex mode
    case $match_mode in
        1) search_pattern="$pattern" ;;
        2) search_pattern=".*$pattern" ;;
        *) search_pattern=".*$pattern.*" ;;
    esac
fi

# Add additional required patterns (-P)
for ap in "${and_patterns[@]}"; do
    if [ $fixed_strings -eq 1 ]; then
        ap_pat="$ap"
    elif [ $use_regex -eq 0 ]; then
        case $match_mode in
            1) ap_pat="**/$ap" ;;
            2) ap_pat="**/*$ap" ;;
            *) ap_pat="**/*$ap*" ;;
        esac
    else
        case $match_mode in
            1) ap_pat="$ap" ;;
            2) ap_pat=".*$ap" ;;
            *) ap_pat=".*$ap.*" ;;
        esac
    fi
    args+=(--and "$ap_pat")
done

run_fd "${args[@]}" "${passthru[@]}" "$search_pattern" "${paths[@]}" "${post_args[@]}"
