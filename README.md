# snapper.sh — text-only project snapshots for LLM prompts (and rebuilds)

> **mascot:** 🐢 a careful little turtle taking snapshots  
> **version:** 0.0.9  
> **type:** portable POSIX `sh` script

`snapper.sh` lets you:

* **snap**: take a *text-only* snapshot of selected files in your project (paths + contents), ideal to paste or upload as LLM context.
* **build**: **recreate** those files and directories later from the snapshot.
* **tree**: list the file structure of a project without content, giving an LLM a high-level overview.
* **strip comments**: remove comments (`//`, `/* */`, and `#`) to reduce token usage when feeding code to LLMs.
* **remove blank lines**: optionally strip all blank lines and trailing whitespace for maximum compactness.

it's intentionally small, dependency-light, and predictable: it prefers `git ls-files` (respecting `.gitignore`), falls back to `find`, and never includes binaries.

---

## quick start

```bash
# 1) put snapper.sh somewhere on your PATH
chmod +x snapper.sh
mv snapper.sh ~/.local/bin/snapper

# 2) from a project directory, capture all go and markdown files + the README
snapper snap -o snapshot.txt '*.go' '**/*.md' '/README.md'

# 3) exclude test files when snapshotting
snapper snap -o snapshot.txt -e '*_test.go' '*.go'

# 4) remove comments to save tokens
snapper snap -r -o snapshot.txt '*.go' '*.js' '*.py'

# 5) remove comments AND blank lines for maximum compactness
snapper snap -r -w -o snapshot.txt '*.go' '*.js' '*.py'

# 6) rebuild into a temp folder (create the folder if missing)
mkdir -p /tmp/restore
snapper build -C /tmp/restore -p -i snapshot.txt
```

result:

* `snapshot.txt` contains a lean, token-efficient list of file paths, each followed by its content fenced as markdown code. there are no headers or other metadata.
* `/tmp/restore` will have the same files re-materialized with the original relative paths.

---

## installation

no build needed. any POSIX shell should work.

```bash
curl -fsSL -o snapper.sh https://raw.githubusercontent.com/code-n-go/snapper/main/snapper.sh
chmod +x snapper.sh
# optional: install to PATH
install -m 0755 snapper.sh /usr/local/bin/snapper
```

---

## usage

```bash
snapper.sh snap  [options] -o <snapshot.txt> <pattern> [pattern...]
snapper.sh build [options] -i <snapshot.txt>
```

### subcommands

* **`snap`** — recursively scan a project and write a text-only snapshot of selected files.
* **`build`** — recreate files and directories from a snapshot produced by `snap`.

### patterns (for `snap`)

you can mix and match patterns. matching is **portable globbing** with a couple of rules:

* **globs** (path or basename): `*.go`, `**/*.md`, `src/**/*.go`, `**/*.(js|ts)`
* **explicit project-root path**: `/README.md`, `/docs/INSTALL.md`
    (leading `/` means *relative to the project root*, **not** the filesystem root.)
* `**` is treated like `*` for portability.
* patterns **without** `/` match **basenames anywhere** (e.g., `*.go`).
* patterns **with** `/` match **full relative paths** (e.g., `cmd/**/main.go`).

### options — `snap`

| option | arg | default | description |
| :--- | :--- | :--- | :--- |
| `-o` | `<path>` | **required** | output snapshot to write. if it exists, script warns and exits (code 3) unless `-f` is set. |
| `-C` | `<dir>` | `.` | project root directory to scan from. |
| `-m` | `<kb>` | `200` | max size per **file** in KB. `0` disables limit. files exceeding the limit are skipped. |
| `-s` | `<num>` | `0` | **split** output into multiple files, each containing at most `<num>` files. `0` disables. |
| `-r` | — | off | **remove comments**: strip `//`, `/* */`, and `#` comments to reduce token usage. **note**: `#` removal is skipped for document formats (.md, .txt, .rst, .doc, .docx, .rtf, .pdf, .org, .adoc, .asciidoc) to preserve structure like markdown headers. |
| `-w` | — | off | **remove blank lines**: strip all blank lines and trailing whitespace from files. can be combined with `-r` for maximum token reduction. |
| `-e` | `<pat>` | — | **exclude** pattern. can be used multiple times. files matching any exclude pattern will be skipped even if they match an include pattern. |
| `-t` | — | off | **tree-only**: output only the paths of matched files, without any content. |
| `-a` | — | off | **all dirs**: disable default ignores (see below). |
| `-q` | — | off | quiet progress/skips (final metrics still printed). |
| `-f` | — | off | force overwrite of output snapshot if it exists. |
| `-h` | — | — | show help and exit. |
| `--version` | — | — | print version and exit. |

### options — `build`

| option | arg | default | description |
| :--- | :--- | :--- | :--- |
| `-i` | `<path>` | **required** | input snapshot file. use `-` to read from stdin. |
| `-C` | `<dir>` | `.` | target root directory to build into. |
| `-f` | — | off | force overwrite of existing files (default is to skip). |
| `-p` | — | off | create the build root directory if it doesn't exist (like `mkdir -p`). |
| `-h` | — | — | show help and exit. |
| `--version` | — | — | print version and exit. |

---

## behavior & guarantees

* **text-only**: binaries are always skipped (detected via `file --mime` if available; otherwise assumed text).
* **git-aware**: if inside a git repo, `snap` uses:

    ```bash
    git ls-files -co --exclude-standard
    ```

    this honors `.gitignore` and includes untracked files. if not a repo, it falls back to `find`.
* **default ignores** (when not using `-a`):
    `.git, .hg, .svn, node_modules, vendor, dist, build, .cache, .idea, .vscode, target, bin, out, coverage`
* **exclude patterns**: files matching any `-e` exclude pattern are skipped even if they match include patterns. exclude patterns use the same matching rules as include patterns.
* **comment removal** (with `-r`):
  * strips `//` line comments (everything from `//` to end of line)
  * strips `/* */` block comments (including multi-line)
  * strips `#` line comments (everything from `#` to end of line)
  * `#` removal is **automatically skipped** for document formats: `.md`, `.txt`, `.rst`, `.doc`, `.docx`, `.rtf`, `.pdf`, `.org`, `.adoc`, `.asciidoc` to preserve structure (e.g., markdown headers)
  * preserves original blank lines (lines that were blank before comment removal)
  * removes comment-only lines entirely
  * removes trailing whitespace from code lines
  * works on any text file
  * **note**: simple pattern-based removal; does not parse strings, so `//`, `/* */`, or `#` inside string literals will also be removed
* **blank line removal** (with `-w`):
  * removes all blank lines from files
  * removes all trailing whitespace after the last non-whitespace character on each line
  * can be combined with `-r` to remove comments first, then blank lines
  * useful for maximum token reduction when feeding code to LLMs
* **language fences**: snapshot wraps each file's content in a markdown code fence with a best-guess language from its extension. this is helpful for LLMs.
* **lean format**: snapshots contain no headers, footers, or metadata. the format is just the file path followed by its fenced content, maximizing token efficiency.
* **metrics**: after snapping, summary metrics print to **stdout** (not embedded in the snapshot) including count by extension and skip reasons.

---

## examples

### 1) focused capture of go and markdown files

```bash
snapper snap -o snapshot.txt '*.go' '**/*.md'
```

the output `snapshot.txt` is lean and ready for an LLM:

```markdown
README.md
` ` `markdown
# Project Title
` ` `

internal/service/foo.go
` ` `go
package service

// ...contents...
` ` `
```

### 2) exclude test files from a go project

```bash
snapper snap -o snapshot.txt -e '*_test.go' '*.go'
```

this captures all `.go` files except those ending in `_test.go`.

### 3) remove comments to reduce token usage

```bash
snapper snap -r -o snapshot.txt '*.go' '*.js' '*.py'
```

this captures source files and strips all comments (`//`, `/* */`, and `#`), significantly reducing the token count for LLM context. note that `#` will be preserved in markdown and other document files automatically.

### 4) remove comments and blank lines for maximum compactness

```bash
snapper snap -r -w -o snapshot.txt '*.go' '*.js' '*.py'
```

combining `-r` and `-w` provides maximum token reduction by first removing comments, then removing all blank lines and trailing whitespace. this creates the most compact possible snapshot.

### 5) combine comment removal with exclusions

```bash
snapper snap -r -o snapshot.txt -e '*_test.go' -e '*.pb.go' '*.go'
```

this removes test files and generated protobuf files, then strips comments from the remaining go files.

### 6) multiple exclude patterns

```bash
snapper snap -o snapshot.txt -e '*_test.go' -e '*.pb.go' -e 'mock_*.go' '*.go'
```

this excludes test files, protocol buffer generated files, and mock files.

### 7) list the project structure without content

use the `-t` (`--tree-only`) flag to generate a simple file list. this is useful for giving an LLM a high-level overview of the project architecture.

```bash
snapper snap -t -o tree.txt '**/*'
```

### 8) split a large project into numbered snapshots

for codebases that exceed an LLM's context window, use the `-s` flag to split the output. this command creates snapshots with 20 files each.

```bash
snapper snap -s 20 -o parts.txt '**/*.js'
```

this produces `parts.txt`, `parts-2.txt`, `parts-3.txt`, etc.

### 9) rebuild from split snapshots

to rebuild a project from split files, `cat` them into the build command via a pipe.

```bash
cat parts-*.txt | snapper build -C /tmp/restore -p -i -
```

### 10) capture everything (no default ignores), with a 1MB file limit

```bash
snapper snap -a -m 1024 -o all.txt '**/*'
```

### 11) exclude vendor and generated code

```bash
snapper snap -o snapshot.txt -e 'vendor/**' -e '**/generated/**' -e '*.gen.go' '*.go'
```

---

## output & exit codes

* the snapshot file is **always written** to the `-o` path (creating or truncating the file) unless prevented by an existing file without `-f`.
* metrics are printed to **stdout** as a separate report, e.g.:

```text
== snapper snap metrics ==
version: 0.0.9
project_root: /home/you/myproj
output: /home/you/myproj/snapshot.txt (and subsequent numbered files if split)
files written: 42
comments: removed
blank lines: removed
by extension:
.go: 31
.md: 8
.json: 3
skipped: size=2 binary=1 excluded=5 no_match=117
```

### exit codes

| code | meaning |
| :--- | :--- |
| `0` | success |
| `3` | `snap`: output snapshot already exists and `-f` not provided |
| `>0` | other error (bad args, cannot cd, unreadable file, etc.) |

---

## rebuild format parser

during `build`, snapper looks for simple blocks of a path on one line followed by a markdown code fence.

```text
<relative/path/to/file.ext>
` ` `<lang?>
<file contents go here>
...
` ` `
```

* the parser expects the file path to be on its own line.
* content is everything between the opening and closing triple backticks.
* the builder creates parent directories as needed.

---

## tips for LLM workflows

* **provide structure first**: use `snapper snap -t` to give the LLM the project's file structure. this helps it understand the overall layout before seeing any code.
* **remove comments**: use `snapper snap -r` to strip comments from source files. comments often contain verbose explanations that consume tokens without adding value for code analysis.
* **maximize compactness**: combine `-r -w` to remove both comments and blank lines for the smallest possible snapshot.
* **split large projects**: use `snapper snap -s <num>` to break large codebases into manageable chunks that fit within your model's context window.
* **exclude noise**: use `-e` to skip test files, generated code, or vendor dependencies that aren't relevant to your prompt (e.g., `-e '*_test.go' -e '*.pb.go' -e 'vendor/**'`).
* **keep snapshots lean**: use patterns, `-m`, `-r`, `-w`, and `-e` to stay within model context limits.
* **include key configs**: e.g., `/Dockerfile`, `**/*.yaml`, `/Makefile`, `/go.mod`, `/README.md`.
* **exclude generated or vendor**: rely on git-aware mode or keep `-a` off, and use `-e` for additional filtering.

---

## security & privacy

* snapper **never** includes binary files. still, review snapshots for secrets before sharing.
* consider adding patterns to exclude secret files (e.g., `-e '**/*.env' -e '**/secrets.yaml'`) or rely on `.gitignore` + not tracking secrets.
* the `-r` flag removes comments but does not parse language syntax, so it may inadvertently modify string literals containing `//` or `/* */`.

---

## compatibility

* requires a POSIX shell (`/bin/sh`).
* uses `git` if available (and inside a repo); otherwise `find`, `sort`, `awk`, `sed`, `wc`, `tr`, and standard coreutils.
* uses `file` for MIME detection if present; otherwise assumes text.

---

## faq

**q: why not include binaries behind a flag?**  
**a:** to keep snapshots safe and small for LLMs; binaries bloat context and aren't useful in text prompts.

**q: how does comment removal work?**  
**a:** the `-r` flag uses a simple pattern-based approach that removes `//` (line comments), `/* */` (block comments), and `#` (line comments). it does not parse language syntax, so it will also remove these patterns if they appear in string literals. **important**: `#` is automatically preserved in document formats (.md, .txt, .rst, etc.) to avoid removing markdown headers and similar structures. for most use cases where you're feeding code to an LLM, this trade-off is acceptable since it significantly reduces token usage.

**q: will comment removal break my code?**  
**a:** the `-r` flag is only used during snapshot creation (with `snap`). it does not modify your original files. if you later use `build` to recreate files from a snapshot that had comments removed, those files will not have comments, but they should still be syntactically valid code.

**q: how do exclude patterns work with include patterns?**  
**a:** files are first matched against include patterns, then checked against exclude patterns. if a file matches any exclude pattern, it's skipped regardless of include matches. this allows you to do things like `'*.go' -e '*_test.go'` to get all go files except tests.

**q: can i exclude entire directories?**  
**a:** yes, use patterns like `-e 'vendor/**'` or `-e '**/generated/**'` to exclude directory trees.

**q: how accurate are the language fences?**  
**a:** they're heuristic, keyed off file extensions only. unknown extensions fall back to plain fenced code.

**q: does `-m` round by bytes or kilobytes?**  
**a:** it's a **per-file byte check** against `KB * 1024` (default 200KB). files larger than the threshold are skipped.

**q: can i snapshot from outside the repo root?**  
**a:** yes, with `-C` you can point to any directory; leading `/` in patterns is relative to that root.

---

## roadmap ideas

* optional manifest of file hashes to detect drift.
* include/exclude pattern lists via file (e.g., `.snapperinclude`, `.snapperexclude`).
* more language mappings for fences.
* a `--dry-run` for snap.
* language-aware comment removal that handles strings properly.

---

## license

[MIT License](./LICENSE)

---

## contributing

* keep POSIX sh compatibility (avoid bash-only features).
* prefer simple, readable pipelines.
* add tests where possible (e.g., via a portable shell test harness).

---

## changelog

* **0.0.9** — `snap`: add `-w` flag to remove all blank lines and trailing whitespace for maximum token reduction. can be combined with `-r` for ultra-compact snapshots. fix `-r` to properly preserve original blank lines while removing comment-only lines.
* **0.0.8** — `snap`: add `#` line comment removal support (shell/Python-style). automatically exempt document formats (.md, .txt, .rst, .doc, .docx, .rtf, .pdf, .org, .adoc, .asciidoc) from `#` removal to preserve structure like markdown headers. **important clarification**: the `-r` flag only affects snapshot content, never modifies original source files.
* **0.0.7** — `snap`: add `-r` flag to remove C-style comments (`//` and `/* */`) from files before snapshotting, reducing token usage for LLM context.
* **0.0.6** — `snap`: add `-e` flag for exclude patterns to skip specific files even if they match include patterns.
* **0.0.5** — `snap`: add `-t` (`--tree-only`) flag to output file paths without content.
* **0.0.4** — `snap`: remove all headers and footers for a leaner, token-efficient output. add `-s` flag to split snapshots into multiple files. `build`: update parser for new format and support reading from `stdin` (`-i -`).
* **0.0.3** — `build`: add `-p` to create build root; `-i` path resolved to absolute before `-C`; fence parsing fix; CRLF-tolerant reader.
* **0.0.2** — `build`: parsing order fix for closing fence; snapshot path absolutized prior to `-C`.
* **0.0.1** — initial release: `snap` (git-aware), `build`, text-only, per-file size limit, metrics, language fences.
