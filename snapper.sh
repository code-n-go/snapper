#!/usr/bin/env sh
# snapper.sh — take a text-only snapshot of repo files (paths + contents) and rebuild them later
# mascot: 🐢 (a careful little turtle taking snapshots)
# version: 0.0.9

set -eu

VERSION="0.0.9"

# defaults for 'snap'
SNAP_MAX_KB=200
SNAP_QUIET=0
SNAP_USE_DEFAULT_IGNORES=1
SNAP_FORCE_OVERWRITE=0
SNAP_OUTPUT=""
SNAP_PROJECT_ROOT="."   # configurable via -C
SNAP_SPLIT_COUNT=0      # configurable via -s
SNAP_TREE_ONLY=0        # configurable via -t
SNAP_EXCLUDE_PATTERNS="" # configurable via -e
SNAP_REMOVE_COMMENTS=0  # configurable via -r
SNAP_REMOVE_BLANKS=0    # configurable via -w

# defaults for 'build'
BUILD_INPUT=""
BUILD_TARGET_ROOT="."   # configurable via -C
BUILD_FORCE=0           # overwrite existing files during build
BUILD_MKDIR=0           # create build root if missing (-p)

emsg() { [ "${SNAP_QUIET:-0}" -eq 1 ] || { printf '%s\n' "$*" >&2; }; }
die()  { printf '%s\n' "error: $*" >&2; exit 1; }

print_help() {
cat <<'H'
snapper — snapshot (snap) text files for LLM prompts and rebuild (build) from the snapshot

USAGE:
  snapper.sh snap  [options] -o <snapshot.txt> <pattern> [pattern...]
  snapper.sh build [options] -i <snapshot.txt>

SUBCOMMANDS:

  snap   Recursively scan a project and write a text-only snapshot of selected files.
         The output is a condensed format ideal for LLMs, containing only file paths and their fenced contents.

  build  Recreate files and directories from a snapshot produced by 'snap'.
         Note: Cannot be used with a snapshot created with the -t flag.

PATTERNS (for 'snap'):
  Globs (path or basename):   *.go   **/*.md   src/**/*.go   **/*.(js|ts)
  Explicit project-root path:  /README.md  /docs/INSTALL.md
  Note: '**' is treated like '*' for portability; patterns without '/' also match basenames.

OPTIONS: snap
  -o <path>   Output snapshot to write. If it exists: warning + exit (unless -f).
  -C <dir>    Project root directory to scan from (default: current dir).
  -m <kb>     Max size per file, in KB (default 200; 0 = no limit).
  -s <num>    Split the output into multiple files, each containing <num> files.
  -t          Tree-only mode: output only the paths of matched files, without content.
  -r          Remove comments from files before snapshotting:
              • // line comments (C-style)
              • /* */ block comments (C-style, including multi-line)
              • # line comments (shell/Python-style)
              Note: # removal is skipped for .md, .txt, .rst, .doc, .docx, .rtf, .pdf,
              .org, .adoc, and .asciidoc files to preserve document structure.
  -w          Remove all blank lines and trailing whitespace from files.
              Can be combined with -r for maximum token reduction.
  -e <pat>    Exclude pattern (can be used multiple times). Files matching any exclude
              pattern will be skipped even if they match an include pattern.
  -a          Include all dirs (disable default ignores like .git, node_modules, vendor, dist...).
  -q          Quiet progress/skips (final metrics still printed).
  -f          Force overwrite of output snapshot if it exists (no prompt).
  -h          Show help and exit.
  --version   Show version and exit.

OPTIONS: build
  -i <path>   Input snapshot to read (required). Use '-' to read from stdin.
  -C <dir>    Target root directory to build into (default: current dir).
  -f          Force overwrite of existing files (default: skip existing).
  -p          Create the build root directory if it doesn't exist.
  -h          Show help and exit.
  --version   Show version and exit.

BEHAVIOR:
  • Only text files are included; binaries are always skipped (no option to include).
  • 'snap' prefers `git ls-files -co --exclude-standard` (honors .gitignore); else falls back to `find`.
  • Metrics print to stdout (not embedded in the snapshot).
  • Comment removal (-r) strips //, /* */, and # comments. Document formats (.md, .txt, etc.)
    are exempt from # removal to preserve structure (e.g., Markdown headers).

EXAMPLES:
  # Create a single, condensed snapshot of Go and Markdown files
  snapper.sh snap -f -o snapshot.txt '*.go' '**/*.md'

  # Remove comments to reduce token usage
  snapper.sh snap -r -o snapshot.txt '*.go' '*.js' '*.py'

  # Remove comments and all blank lines for maximum compactness
  snapper.sh snap -r -w -o snapshot.txt '*.go' '*.js' '*.py'

  # Exclude test files when snapshotting Go files
  snapper.sh snap -o snapshot.txt -e '*_test.go' '*.go'

  # Multiple exclude patterns
  snapper.sh snap -o snapshot.txt -e '*_test.go' -e '*.pb.go' -e 'mock_*.go' '*.go'

  # Create a file list showing the project's structure, without any code
  snapper.sh snap -t -o tree.txt '**/*'

  # Rebuild from a snapshot (or a chain of snapshots)
  cat snapshot.txt snapshot-2.txt | snapper.sh build -C /tmp/restore -p -i -
H
}

if [ "${1:-""}" = "--version" ]; then printf '%s\n' "$VERSION"; exit 0; fi
if [ "${1:-""}" = "--help" ] || [ "${1:-""}" = "" ]; then print_help; exit 0; fi

subcmd="$1"; shift

################################################################################
# shared helpers
################################################################################

# text detection — always skip binaries
is_text_file() {
  _f=$1
  if command -v file >/dev/null 2>&1; then
    _m=$(file -b --mime "$_f" 2>/dev/null || printf '%s' '')
    case $_m in text/*|*charset*) return 0 ;; *) return 1 ;; esac
  else
    # if 'file' is unavailable, assume text
    return 0
  fi
}

# strip comments from a file
# handles: // line comments, /* */ block comments (including multi-line), and # line comments
# _strip_hash parameter: 0=skip # removal (for .md, .txt, etc.), 1=remove # comments
strip_comments() {
  _infile=$1
  _outfile=$2
  _strip_hash=$3

  _in_block=0
  _line_num=0

  while IFS= read -r _line || [ -n "$_line" ]; do
    _line_num=$((_line_num + 1))
    _output=""
    _i=1
    _len=${#_line}

    # Check if original line is blank or whitespace-only
    _original_trimmed=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _originally_blank=0
    if [ -z "$_original_trimmed" ]; then
      _originally_blank=1
    fi

    # Process character by character
    while [ $_i -le $_len ]; do
      _char=$(printf '%s' "$_line" | cut -c $_i)
      _next_char=""
      if [ $_i -lt $_len ]; then
        _next_char=$(printf '%s' "$_line" | cut -c $((_i + 1)))
      fi

      # If we're in a block comment, look for */
      if [ $_in_block -eq 1 ]; then
        if [ "$_char" = "*" ] && [ "$_next_char" = "/" ]; then
          _in_block=0
          _i=$((_i + 2))
          continue
        fi
        _i=$((_i + 1))
        continue
      fi

      # Check for start of block comment /*
      if [ "$_char" = "/" ] && [ "$_next_char" = "*" ]; then
        _in_block=1
        _i=$((_i + 2))
        continue
      fi

      # Check for line comment //
      if [ "$_char" = "/" ] && [ "$_next_char" = "/" ]; then
        # Rest of line is a comment, break from character loop
        break
      fi

      # Check for # line comment (if enabled for this file type)
      if [ "$_strip_hash" -eq 1 ] && [ "$_char" = "#" ]; then
        # Rest of line is a comment, break from character loop
        break
      fi

      # Regular character, add to output
      _output="${_output}${_char}"
      _i=$((_i + 1))
    done

    # Decide whether to write the line:
    # 1. If originally blank/whitespace-only, preserve it as blank
    # 2. Otherwise, check if we extracted any code after comment removal
    #    - If yes, write it (after trimming trailing whitespace)
    #    - If no, skip the line (it was comment-only)

    if [ $_originally_blank -eq 1 ]; then
      # Original line was blank or whitespace-only, preserve it
      printf '\n' >> "$_outfile"
    else
      # Original line had content, check what remains after comment removal
      _trimmed=$(printf '%s' "$_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$_trimmed" ]; then
        # Line has code, write it (with trailing whitespace removed)
        _output=$(printf '%s' "$_output" | sed 's/[[:space:]]*$//')
        printf '%s\n' "$_output" >> "$_outfile"
      fi
      # Otherwise skip the line (it was comment-only)
    fi
  done < "$_infile"
}

# remove blank lines and trailing whitespace from a file
remove_blank_lines() {
  _infile=$1
  _outfile=$2

  while IFS= read -r _line || [ -n "$_line" ]; do
    # Remove trailing whitespace
    _line=$(printf '%s' "$_line" | sed 's/[[:space:]]*$//')

    # Only write non-empty lines
    if [ -n "$_line" ]; then
      printf '%s\n' "$_line" >> "$_outfile"
    fi
  done < "$_infile"
}

################################################################################
# SNAP
################################################################################
snap_list_candidates() {
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard
  else
    if [ "$SNAP_USE_DEFAULT_IGNORES" -eq 1 ]; then
      find . -type d \( -name .git -o -name .hg -o -name .svn -o -name node_modules -o -name vendor -o -name dist -o -name build -o -name .cache -o -name .idea -o -name .vscode -o -name target -o -name bin -o -name out -o -name coverage \) -prune -o -type f -print
    else
      find . -type f -print
    fi | sed 's#^\./##'
  fi
}

# portable matcher: collapse ** -> *; try path match then basename match
snap_match_pattern() {
  _pat=$1
  _file=$2
  case $_pat in
    /*)
      [ -f "${_pat#/}" ] && [ "$_file" = "${_pat#/}" ] && return 0 || return 1 ;;
  esac
  _ppat=$(printf '%s' "$_pat" | sed 's#\*\*#*#g')
  case $_file in $_ppat) return 0 ;; esac
  _base=${_file##*/}
  case $_base in $_ppat) return 0 ;; esac
  return 1
}

snap_lang_fence() {
  _f=$1; _ext=${_f##*.}
  case $_ext in
    go)   printf '%s' go ;;
    js)   printf '%s' javascript ;;
    ts)   printf '%s' typescript ;;
    json) printf '%s' json ;;
    yml|yaml) printf '%s' yaml ;;
    md)   printf '%s' markdown ;;
    sh|zsh|bash) printf '%s' bash ;;
    py)   printf '%s' python ;;
    rb)   printf '%s' ruby ;;
    rs)   printf '%s' rust ;;
    c|h)  printf '%s' c ;;
    cpp|cc|cxx|hpp) printf '%s' cpp ;;
    java) printf '%s' java ;;
    kt|kts) printf '%s' kotlin ;;
    swift) printf '%s' swift ;;
    cs)   printf '%s' csharp ;;
    html) printf '%s' html ;;
    css)  printf '%s' css ;;
    scss|sass) printf '%s' scss ;;
    xml)  printf '%s' xml ;;
    sql)  printf '%s' sql ;;
    lua)  printf '%s' lua ;;
    vim)  printf '%s' vim ;;
    m)    printf '%s' objectivec ;;
    dart) printf '%s' dart ;;
    scala) printf '%s' scala ;;
    pl|pm) printf '%s' perl ;;
    r)    printf '%s' r ;;
    ex|exs) printf '%s' elixir ;;
    erl|hrl) printf '%s' erlang ;;
    clj|cljs|cljc) printf '%s' clojure ;;
    lisp|el) printf '%s' lisp ;;
    hs|lhs) printf '%s' haskell ;;
    ml|mli) printf '%s' ocaml ;;
    fs|fsi|fsx) printf '%s' fsharp ;;
    nim)  printf '%s' nim ;;
    v)    printf '%s' v ;;
    zig)  printf '%s' zig ;;
    *)    printf '%s' '' ;;
  esac
}

run_snap() {
  while getopts "o:C:m:s:te:aqfrwh" opt; do
    case "$opt" in
      o) SNAP_OUTPUT="$OPTARG" ;;
      C) SNAP_PROJECT_ROOT="$OPTARG" ;;
      m) SNAP_MAX_KB="$OPTARG" ;;
      s) SNAP_SPLIT_COUNT="$OPTARG" ;;
      t) SNAP_TREE_ONLY=1 ;;
      e) SNAP_EXCLUDE_PATTERNS="${SNAP_EXCLUDE_PATTERNS}${OPTARG}"$'\n' ;;
      a) SNAP_USE_DEFAULT_IGNORES=0 ;;
      q) SNAP_QUIET=1 ;;
      f) SNAP_FORCE_OVERWRITE=1 ;;
      r) SNAP_REMOVE_COMMENTS=1 ;;
      w) SNAP_REMOVE_BLANKS=1 ;;
      h) print_help; exit 0 ;;
      \?) die "unknown flag -$OPTARG (use -h)" ;;
      :)  die "flag -$OPTARG requires an argument" ;;
    esac
  done
  shift $((OPTIND-1))

  [ -n "$SNAP_OUTPUT" ] || die "output snapshot is required (-o <path>)"
  [ $# -gt 0 ] || die "at least one pattern is required (e.g., '*.go')"

  cd "$SNAP_PROJECT_ROOT" 2>/dev/null || die "cannot cd to $SNAP_PROJECT_ROOT"
  SNAP_PROJECT_ROOT_ABS="$(pwd -P)"

  # Resolve output path to absolute before changing dirs
  case "$SNAP_OUTPUT" in
    /*) SNAP_OUTPUT_BASE="$SNAP_OUTPUT" ;;
    *)  SNAP_OUTPUT_BASE="$SNAP_PROJECT_ROOT_ABS/$SNAP_OUTPUT" ;;
  esac

  if [ "$SNAP_FORCE_OVERWRITE" -ne 1 ] && [ -e "$SNAP_OUTPUT_BASE" ]; then
    die "output snapshot already exists: $SNAP_OUTPUT_BASE (use -f to overwrite)"
  fi

  TMP_CAND=$(mktemp "${TMPDIR:-/tmp}/snapper.cand.XXXXXX")
  TMP_METR=$(mktemp "${TMPDIR:-/tmp}/snapper.metr.XXXXXX")
  TMP_STRIPPED=$(mktemp "${TMPDIR:-/tmp}/snapper.stripped.XXXXXX")
  TMP_NOBLANKS=$(mktemp "${TMPDIR:-/tmp}/snapper.noblanks.XXXXXX")
  trap 'rm -f "$TMP_CAND" "$TMP_METR" "$TMP_STRIPPED" "$TMP_NOBLANKS"' EXIT HUP INT TERM

  snap_list_candidates | sort > "$TMP_CAND"

  INCLUDED=0
  SKIP_SIZE=0
  SKIP_BIN=0
  SKIP_NOMATCH=0
  SKIP_EXCLUDE=0

  CURRENT_SNAPSHOT_INDEX=1
  CURRENT_FILE_COUNT=0

  get_snapshot_filename() {
    if [ "$SNAP_SPLIT_COUNT" -eq 0 ] || [ "$CURRENT_SNAPSHOT_INDEX" -eq 1 ]; then
      printf '%s' "$SNAP_OUTPUT_BASE"
    else
      base_name="${SNAP_OUTPUT_BASE%.*}"
      base_ext="${SNAP_OUTPUT_BASE##*.}"
      if [ "$base_name" = "$SNAP_OUTPUT_BASE" ]; then
        printf '%s-%s' "$SNAP_OUTPUT_BASE" "$CURRENT_SNAPSHOT_INDEX"
      else
        printf '%s-%s.%s' "$base_name" "$CURRENT_SNAPSHOT_INDEX" "$base_ext"
      fi
    fi
  }

  CURRENT_SNAPSHOT_FILE=$(get_snapshot_filename)
  : > "$CURRENT_SNAPSHOT_FILE" || die "cannot write to $CURRENT_SNAPSHOT_FILE"

  while IFS= read -r f; do
    [ -f "$f" ] || continue

    matched=1
    for pat in "$@"; do
      if snap_match_pattern "$pat" "$f"; then matched=0; break; fi
    done
    if [ $matched -ne 0 ]; then
      SKIP_NOMATCH=$((SKIP_NOMATCH+1)); continue
    fi

    # Check exclude patterns
    if [ -n "$SNAP_EXCLUDE_PATTERNS" ]; then
      excluded=1
      while IFS= read -r excl_pat; do
        [ -n "$excl_pat" ] || continue
        if snap_match_pattern "$excl_pat" "$f"; then
          excluded=0
          break
        fi
      done <<EOF
$SNAP_EXCLUDE_PATTERNS
EOF
      if [ $excluded -eq 0 ]; then
        emsg "skip (excluded): $f"
        SKIP_EXCLUDE=$((SKIP_EXCLUDE+1))
        continue
      fi
    fi

    if [ "$SNAP_TREE_ONLY" -ne 1 ]; then
        if ! is_text_file "$f"; then
          emsg "skip (binary): $f"
          SKIP_BIN=$((SKIP_BIN+1))
          continue
        fi

        bytes=$(wc -c < "$f" 2>/dev/null || echo 0)
        if [ "$SNAP_MAX_KB" -gt 0 ] && [ "$bytes" -gt $((SNAP_MAX_KB * 1024)) ]; then
          emsg "skip (size>${SNAP_MAX_KB}KB): $f"
          SKIP_SIZE=$((SKIP_SIZE+1))
          continue
        fi
    fi

    if [ "$SNAP_SPLIT_COUNT" -gt 0 ] && [ "$CURRENT_FILE_COUNT" -ge "$SNAP_SPLIT_COUNT" ]; then
        CURRENT_FILE_COUNT=0
        CURRENT_SNAPSHOT_INDEX=$((CURRENT_SNAPSHOT_INDEX + 1))
        CURRENT_SNAPSHOT_FILE=$(get_snapshot_filename)
        : > "$CURRENT_SNAPSHOT_FILE" || die "cannot write to $CURRENT_SNAPSHOT_FILE"
    fi

    base=${f##*/}
    ext=${base##*.}
    if [ "$ext" = "$base" ] || [ -z "$ext" ]; then ext="(noext)"; fi
    case "$ext" in *[A-Z]*) ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]');; esac
    printf '%s\n' "$ext" >> "$TMP_METR"

    if [ "$SNAP_TREE_ONLY" -eq 1 ]; then
        printf '%s\n' "$f" >> "$CURRENT_SNAPSHOT_FILE"
    else
        lang=$(snap_lang_fence "$f")

        # Process file through the pipeline based on enabled flags
        _source_file="$f"

        # Step 1: Remove comments if requested
        if [ "$SNAP_REMOVE_COMMENTS" -eq 1 ]; then
          : > "$TMP_STRIPPED"

          # Determine if we should strip # comments based on file extension
          # Skip # removal for document formats where # has special meaning
          _strip_hash=1
          case "$ext" in
            md|txt|rst|doc|docx|rtf|pdf|org|adoc|asciidoc)
              _strip_hash=0
              ;;
          esac

          strip_comments "$_source_file" "$TMP_STRIPPED" "$_strip_hash"
          _source_file="$TMP_STRIPPED"
        fi

        # Step 2: Remove blank lines if requested
        if [ "$SNAP_REMOVE_BLANKS" -eq 1 ]; then
          : > "$TMP_NOBLANKS"
          remove_blank_lines "$_source_file" "$TMP_NOBLANKS"
          _source_file="$TMP_NOBLANKS"
        fi

        {
          printf '%s\n' "$f"
          if [ -n "$lang" ]; then printf '%s%s\n' '```' "$lang"; else printf '%s\n' '```'; fi
          cat -- "$_source_file"
          printf '\n%s\n' '```'
          printf '\n'
        } >> "$CURRENT_SNAPSHOT_FILE"
    fi

    INCLUDED=$((INCLUDED+1))
    CURRENT_FILE_COUNT=$((CURRENT_FILE_COUNT + 1))
  done < "$TMP_CAND"

  printf '%s\n' "== snapper snap metrics =="
  printf '%s\n' "version: $VERSION"
  printf '%s\n' "project_root: $SNAP_PROJECT_ROOT_ABS"
  printf '%s\n' "output: $SNAP_OUTPUT_BASE (and subsequent numbered files if split)"
  if [ "$SNAP_TREE_ONLY" -eq 1 ]; then
    printf '%s\n' "files listed: $INCLUDED"
  else
    printf '%s\n' "files written: $INCLUDED"
  fi
  if [ "$SNAP_REMOVE_COMMENTS" -eq 1 ]; then
    printf '%s\n' "comments: removed"
  fi
  if [ "$SNAP_REMOVE_BLANKS" -eq 1 ]; then
    printf '%s\n' "blank lines: removed"
  fi
  if [ -s "$TMP_METR" ]; then
    printf '%s\n' "by extension:"
    awk '{c[$0]++} END {for (k in c) printf "%s %d\n", k, c[k]}' "$TMP_METR" \
      | sort -k2,2nr -k1,1 \
      | while IFS=' ' read -r k v; do
          case "$k" in
            \(noext\)) printf '%s\n' "(noext): $v" ;;
            *)         printf '.%s: %s\n' "$k" "$v" ;;
          esac
        done
  fi
  printf '%s\n' "skipped: size=$SKIP_SIZE binary=$SKIP_BIN excluded=$SKIP_EXCLUDE no_match=$SKIP_NOMATCH"
}

################################################################################
# BUILD
################################################################################
run_build() {
  while getopts "i:C:fph" opt; do
    case "$opt" in
      i) BUILD_INPUT="$OPTARG" ;;
      C) BUILD_TARGET_ROOT="$OPTARG" ;;
      f) BUILD_FORCE=1 ;;
      p) BUILD_MKDIR=1 ;;
      h) print_help; exit 0 ;;
      \?) die "unknown flag -$OPTARG (use -h)" ;;
      :)  die "flag -$OPTARG requires an argument" ;;
    esac
  done
  shift $((OPTIND-1))

  [ -n "$BUILD_INPUT" ] || die "input snapshot is required (-i <path>)"

  # resolve snapshot to absolute path before changing directories
  START_DIR="$(pwd -P)"
  if [ "$BUILD_INPUT" = "-" ]; then
    BUILD_INPUT_ABS="/dev/stdin"
  else
    case "$BUILD_INPUT" in
      /*) BUILD_INPUT_ABS="$BUILD_INPUT" ;;
      *)  BUILD_INPUT_ABS="$START_DIR/$BUILD_INPUT" ;;
    esac
    [ -f "$BUILD_INPUT_ABS" ] || die "snapshot not found: $BUILD_INPUT_ABS"
  fi

  # ensure/enter build root
  if [ ! -d "$BUILD_TARGET_ROOT" ]; then
    if [ "$BUILD_MKDIR" -eq 1 ]; then
      mkdir -p -- "$BUILD_TARGET_ROOT" 2>/dev/null || die "cannot create build root: $BUILD_TARGET_ROOT"
    else
      die "cannot cd to build root: $BUILD_TARGET_ROOT (use -p to create it)"
    fi
  fi
  cd "$BUILD_TARGET_ROOT" 2>/dev/null || die "cannot cd to build root after create: $BUILD_TARGET_ROOT"
  BUILD_ROOT_ABS="$(pwd -P)"

  CREATED=0
  OVERWRITTEN=0
  SKIPPED_EXISTS=0
  PARSE_ERRORS=0

  in_code=0
  current_path=""
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/snapper.build.XXXXXX")
  trap 'rm -f "$tmpfile"' EXIT HUP INT TERM

  cr="$(printf '\r')"

  # read snapshot (already absolute) and parse fenced blocks
  while IFS= read -r line || [ -n "$line" ]; do
    # strip trailing CR (handles CRLF snapshots)
    case $line in *"$cr") line=${line%"$cr"} ;; esac
    case "$in_code:$line" in
      0:\`\`\`*)
        in_code=1
        ;;
      0:*)
        current_path="$line"
        : > "$tmpfile"
        ;;
      1:\`\`\`)
        dirp=$(dirname -- "$current_path")
        [ -d "$dirp" ] || mkdir -p -- "$dirp"
        if [ -e "$current_path" ] && [ "$BUILD_FORCE" -ne 1 ]; then
          SKIPPED_EXISTS=$((SKIPPED_EXISTS+1))
        else
          if [ -e "$current_path" ] && [ "$BUILD_FORCE" -eq 1 ]; then
            OVERWRITTEN=$((OVERWRITTEN+1))
          else
            CREATED=$((CREATED+1))
          fi
          umask 022
          cp "$tmpfile" "$current_path"
        fi
        in_code=0
        current_path=""
        : > "$tmpfile"
        ;;
      1:*)
        printf '%s\n' "$line" >> "$tmpfile"
        ;;
      *)
        PARSE_ERRORS=$((PARSE_ERRORS+1))
        ;;
    esac
  done < "$BUILD_INPUT_ABS"

  printf '%s\n' "== snapper build metrics =="
  printf '%s\n' "version: $VERSION"
  printf '%s\n' "build_root: $BUILD_ROOT_ABS"
  printf '%s\n' "snapshot: $BUILD_INPUT_ABS"
  printf '%s\n' "created: $CREATED overwritten: $OVERWRITTEN skipped_exists: $SKIPPED_EXISTS parse_errors: $PARSE_ERRORS"
}

################################################################################
# dispatch
################################################################################
case "$subcmd" in
  snap)  run_snap "$@" ;;
  build) run_build "$@" ;;
  -h|--help) print_help ;;
  *) die "unknown subcommand '$subcmd' (use --help)" ;;
esac