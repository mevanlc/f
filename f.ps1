# f.ps1 - fd wrapper with convenient defaults (PowerShell 7+ port)
# License: MIT (see LICENSE.txt)
# Manual arg parsing because PowerShell params are case-insensitive.

$ErrorActionPreference = 'Stop'

# Locate fd binary
$fdBin = if ($env:F_FD_BIN) {
    $env:F_FD_BIN
} elseif (Get-Command fd -ErrorAction SilentlyContinue) {
    'fd'
} elseif (Get-Command fdfind -ErrorAction SilentlyContinue) {
    'fdfind'
} else {
    Write-Error 'error: fd binary not found (looked for: fd, fdfind; set F_FD_BIN=/path/to/fd)'
    exit 127
}

if ($env:F_FD_BIN -and -not (Test-Path $fdBin)) {
    Write-Error "error: F_FD_BIN is not executable: $fdBin"
    exit 127
}

$fdDbg = $env:F_FD_DBG -eq '1'

# --- Parse arguments manually (case-sensitive) ---
$files_only = $false
$dirs_only = $false
$executable_type = $false
$respect_gitignore = $false
$respect_hidden = $false
$non_empty = $false
$matchMode = 0  # 0=*contains* 1=exact 2=tail
$use_regex = $false
$basename_only = $false
$absolute_path = $false
$max_depth = ''
$max_results = ''
$print0 = $false
$one_file_system = $false
$changed_within = ''
$changed_before = ''
$list_details = $false
$case_sensitive = $false
$fixed_strings = $false
$follow_links = $false
$show_vcs = $false
$show_help = $false
$extensions = [System.Collections.Generic.List[string]]::new()
$types = [System.Collections.Generic.List[string]]::new()
$excludes = [System.Collections.Generic.List[string]]::new()
$and_patterns = [System.Collections.Generic.List[string]]::new()
$sizes = [System.Collections.Generic.List[string]]::new()
$exec_mode = ''
$exec_cmd = ''

$positional = [System.Collections.Generic.List[string]]::new()
$passthru = [System.Collections.Generic.List[string]]::new()

# Flags that consume the next argument
$valFlags = [System.Collections.Generic.HashSet[char]]::new(
    [char[]]@('D','e','t','E','P','A','B','S','x','X')
)

$rawArgs = $args
$i = 0
$sawDashDash = $false
$doneFlags = $false

while ($i -lt $rawArgs.Count) {
    $arg = [string]$rawArgs[$i]

    if ($sawDashDash) {
        $passthru.Add($arg); $i++; continue
    }

    if ($arg -ceq '--') {
        $sawDashDash = $true; $i++; continue
    }

    # Once we see a non-flag, everything remaining is positional (until --)
    if ($doneFlags -or $arg -notmatch '^-[a-zA-Z?]') {
        $doneFlags = $true
        $positional.Add($arg); $i++; continue
    }

    # Expand bundled flags: -fd -> -f -d, but value-flags consume rest or next arg
    $flagStr = $arg.Substring(1)
    $j = 0
    while ($j -lt $flagStr.Length) {
        $ch = $flagStr[$j]
        if ($valFlags.Contains($ch)) {
            # Rest of bundle is the value, or next arg
            $val = if ($j + 1 -lt $flagStr.Length) {
                $flagStr.Substring($j + 1)
            } else {
                $i++
                if ($i -ge $rawArgs.Count) {
                    Write-Error "error: -$ch requires an argument"
                    exit 1
                }
                [string]$rawArgs[$i]
            }
            switch ($ch) {
                'D' { $max_depth = $val }
                'e' { $extensions.Add($val) }
                't' { $types.Add($val) }
                'E' { $excludes.Add($val) }
                'P' { $and_patterns.Add($val) }
                'S' { $sizes.Add($val) }
                'A' { $changed_within = $val }
                'B' { $changed_before = $val }
                'x' { $exec_mode = 'exec'; $exec_cmd = $val }
                'X' { $exec_mode = 'exec-batch'; $exec_cmd = $val }
            }
            break  # value consumed rest of bundle
        }
        switch ($ch) {
            'z' { $print0 = $true }
            'f' { $files_only = $true }
            'd' { $dirs_only = $true }
            'b' { $executable_type = $true }
            'O' { $respect_hidden = $true }
            'Q' { $max_results = '1' }
            'N' { $non_empty = $true }
            'w' { $matchMode = 1 }
            'T' { $matchMode = 2 }
            'G' { $respect_gitignore = $true }
            'C' { $case_sensitive = $true }
            'r' { $use_regex = $true }
            'n' { $basename_only = $true }
            'a' { $absolute_path = $true }
            'l' { $list_details = $true }
            'L' { $follow_links = $true }
            'F' { $fixed_strings = $true }
            'V' { $show_vcs = $true }
            'm' { $one_file_system = $true }
            'h' { $show_help = $true }
            '?' { $show_help = $true }
            default {
                Write-Error "error: unknown flag: -$ch"
                Write-Error 'Usage: f [options] [pattern] [path...]'
                exit 1
            }
        }
        $j++
    }
    $i++
}

# --- Validation ---
if ($max_depth -and $max_depth -notmatch '^\d+$') {
    Write-Error "error: -D expects a non-negative integer depth, got: $max_depth"
    exit 2
}

if ($fixed_strings -and $use_regex) {
    Write-Error 'error: -F (fixed strings) cannot be combined with -r (regex)'
    exit 2
}

if ($fixed_strings -and $matchMode -ne 0) {
    Write-Error 'error: -F (fixed strings) cannot be combined with -w/-T match modes'
    exit 2
}

# --- Time help ---
if ($changed_within -eq 'help' -or $changed_before -eq 'help') {
    Write-Output 'Time formats (for -A/-B):'
    Write-Output '  durations: 10h, 1d, 35min, 2weeks'
    Write-Output "  dates:     'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', '@unix_timestamp'"
    exit 0
}

if ($sizes -contains 'help') {
    @'
Size formats (for -S):
  prefix: +  (at least)    -  (at most)    (none = exactly)
  units:  b  k  m  g  t    (base-10)
          ki mi gi ti      (base-2)

  examples: +100k  -1m  4gi  +0b
  -N is shorthand for -S +1b (non-empty)
'@
    exit 0
}

if ($types -contains 'help') {
    @'
File types (for -t):
  f  file             d  directory
  l  symlink          x  executable
  e  empty            s  socket
  p  pipe (FIFO)      b  block-device
  c  char-device

  Multiple types combine as OR. Comma-separated or repeated.
  -f/-d/-b are shorthand for -t f, -t d, -t x
'@
    exit 0
}

if ($exec_mode -ceq 'exec' -and $exec_cmd -ceq 'help') {
    @'
Exec per match (-x <cmd>):
  Runs <cmd> for each result (in parallel).

  placeholders:
    {}    path                {/}   basename
    {//}  parent directory    {.}   path without extension
    {/.}  basename without extension
    {{    literal {           }}    literal }

  If no placeholder is present, {} is appended implicitly.

  examples:
    f -e zip -x unzip
    f -e jpg -x convert {} {.}.png
'@
    exit 0
}

if ($exec_mode -ceq 'exec-batch' -and $exec_cmd -ceq 'help') {
    @'
Exec in batches (-X <cmd>):
  Runs <cmd> once with all results as arguments.

  placeholders:
    {}    path                {/}   basename
    {//}  parent directory    {.}   path without extension
    {/.}  basename without extension
    {{    literal {           }}    literal }

  If no placeholder is present, {} is appended implicitly.

  examples:
    f -e py -X vim
    f -e rs -X wc -l
'@
    exit 0
}

# --- Help ---
if ($show_help) {
    @'
Usage: f [options] [pattern] [path...]

Switches:
  -f  files
  -d  directories
  -b  executables (bin)
  -w  do not surround with wildcards
  -T  Tail match (ends with)
  -G  respect Git/.ignore rules
  -O  hide dOtfiles
  -r  use regex (default: glob)
  -F  use Fixed strings (not regex/glob)
  -n  search only basenames
  -a  display absolute paths
  -C  Case-sensitive
  -l  list path details (like ls -l)
  -L  follow symLinked directories
  -V  include Vcs metadata (.git, .svn, .hg)
  -m  stay on one filesystem (mount)
  -N  hide empty files
  -Q  print only one result
  -z  delimit results with NULs
  -h  show this help

Flags:
  -D <depth>      max search Depth
  -e <ext>        file extension +
  -t <type|help>  file types (kinds) +
  -E <glob>       Exclude +
  -P <pat>        add required Pattern +
  -S <size|help>  Size filter +
  -A <time|help>  changed After (or within)
  -B <time|help>  changed Before (older than)
  -x <cmd|help>   exec for each match
  -X <cmd|help>   eXec in batches
  -- <fd-args>    forward <fd-args> to fd
+ = indicates a repeatable flag

Defaults differ from fd:
  bypass ignore rules, search hidden, search pathnames,
  ignore-case, glob (vs. regex), automatic wildcards,
  exclude VCS metadata (.git, .svn, .hg)
'@
    exit 0
}

# --- Build fd arguments ---
$fdArgs = [System.Collections.Generic.List[string]]::new()

if ($case_sensitive) { $fdArgs.Add('-s') } else { $fdArgs.Add('-i') }

# Hidden/ignored defaults (include both unless flags set)
if (-not $respect_hidden) { $fdArgs.Add('-H') }
if (-not $respect_gitignore) { $fdArgs.Add('-I') }

if ($follow_links) { $fdArgs.Add('-L') }

# Output format
if ($print0) { $fdArgs.Add('--print0') }
if ($list_details) { $fdArgs.Add('--list-details') }

# Full path vs basename
if (-not $basename_only) { $fdArgs.Add('-p') }

# Glob vs regex vs fixed strings
if ($fixed_strings) { $fdArgs.Add('-F') }
elseif (-not $use_regex) { $fdArgs.Add('-g') }

# Result limit
if ($max_results) { $fdArgs.Add('--max-results'); $fdArgs.Add($max_results) }

# Type filters (-f/-d/-b) and explicit types (-t) combine as OR filters
$allTypes = [System.Collections.Generic.List[string]]::new()
if ($files_only) { $allTypes.Add('f') }
if ($dirs_only) { $allTypes.Add('d') }
if ($executable_type) { $allTypes.Add('x') }
foreach ($tv in $types) {
    foreach ($st in ($tv -split ',')) {
        if ($st) { $allTypes.Add($st) }
    }
}
foreach ($tv in $allTypes) {
    $fdArgs.Add('-t'); $fdArgs.Add($tv)
}

if ($absolute_path) { $fdArgs.Add('-a') }

# Size filters
if ($non_empty) { $fdArgs.Add('-S+1b') }
foreach ($sz in $sizes) {
    $fdArgs.Add('-S'); $fdArgs.Add($sz)
}

# Depth
if ($max_depth) { $fdArgs.Add('--max-depth'); $fdArgs.Add($max_depth) }

# Time filters
if ($changed_within) { $fdArgs.Add('--changed-within'); $fdArgs.Add($changed_within) }
if ($changed_before) { $fdArgs.Add('--changed-before'); $fdArgs.Add($changed_before) }

# Extension filters
foreach ($ext in $extensions) {
    $fdArgs.Add('-e'); $fdArgs.Add($ext)
}

# Exec options (placed after pattern/paths)
$postArgs = @()
if ($exec_mode -eq 'exec') { $postArgs = @('-x', $exec_cmd) }
elseif ($exec_mode -eq 'exec-batch') { $postArgs = @('-X', $exec_cmd) }

# Filesystem boundary
if ($one_file_system) { $fdArgs.Add('--one-file-system') }

# VCS metadata directories excluded by default; -V to include
if (-not $show_vcs) {
    $fdArgs.Add('--exclude=.git')
    $fdArgs.Add('--exclude=.svn')
    $fdArgs.Add('--exclude=.hg')
}

# Excludes
foreach ($ex in $excludes) {
    $fdArgs.Add("--exclude=$ex")
}

# --- Run fd ---
function Invoke-Fd {
    param([string[]]$CmdArgs)
    if ($fdDbg) {
        $display = (@($fdBin) + $CmdArgs) -join ' '
        Write-Host $display -ForegroundColor DarkGray
    }
    & $fdBin @CmdArgs
    exit $LASTEXITCODE
}

# No pattern: run fd with just filters
if ($positional.Count -eq 0) {
    $cmd = @($fdArgs) + @($passthru) + $postArgs
    Invoke-Fd $cmd
}

$pattern = $positional[0]
$paths = if ($positional.Count -gt 1) { $positional[1..($positional.Count - 1)] } else { @() }

# Build search pattern
if ($fixed_strings) {
    $searchPattern = $pattern
} elseif (-not $use_regex) {
    if ($basename_only) {
        $searchPattern = switch ($matchMode) {
            1 { $pattern }
            2 { "*$pattern" }
            default { "*$pattern*" }
        }
    } else {
        $searchPattern = switch ($matchMode) {
            1 { "**/$pattern" }
            2 { "**/*$pattern" }
            default { "**/*$pattern*" }
        }
    }
} else {
    $searchPattern = switch ($matchMode) {
        1 { $pattern }
        2 { ".*$pattern" }
        default { ".*$pattern.*" }
    }
}

# Add additional required patterns (-P)
foreach ($ap in $and_patterns) {
    if ($fixed_strings) {
        $apPat = $ap
    } elseif (-not $use_regex) {
        if ($basename_only) {
            $apPat = switch ($matchMode) {
                1 { $ap }
                2 { "*$ap" }
                default { "*$ap*" }
            }
        } else {
            $apPat = switch ($matchMode) {
                1 { "**/$ap" }
                2 { "**/*$ap" }
                default { "**/*$ap*" }
            }
        }
    } else {
        $apPat = switch ($matchMode) {
            1 { $ap }
            2 { ".*$ap" }
            default { ".*$ap.*" }
        }
    }
    $fdArgs.Add('--and'); $fdArgs.Add($apPat)
}

$cmd = @($fdArgs) + @($passthru) + @($searchPattern) + $paths + $postArgs
Invoke-Fd $cmd
