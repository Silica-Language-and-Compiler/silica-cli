# silica-cli

The `silica` command: build and run Silica programs without writing a Makefile.

```bash
./install.sh                     # links ~/.silica/bin/silica and downloads the compiler
export PATH="$HOME/.silica/bin:$PATH"

silica build hello.silica        # compile + assemble + link
silica run hello.silica          # build, then execute
silica run my_app/               # a project folder (main.silica is the entry point)
silica run my_app -- arg1 arg2   # arguments after -- go to the program
silica build my_app -o bin/app   # choose where the executable goes
silica update                    # fetch the newest released compiler
silica version
```

## Layout

```
silica-cli/
├── src/silica.sh   the CLI itself (a bash script — this is the source)
├── silica          launcher, so ./silica works from this folder
├── install.sh      links ~/.silica/bin/silica -> src/silica.sh, downloads the compiler
├── examples/       sample programs (hello-world)
├── tests/run.sh    end-to-end tests
└── README.md
```

Because the installed command is a symlink to `src/silica.sh`, edits to the source take
effect immediately; there is nothing to compile.

## The compiler

On first use, if `~/.silica/bin/silica-compiler` is missing, `silica` asks GitHub for the
[latest release](https://github.com/Silica-Language-and-Compiler/silica/releases/latest) and
downloads the compiler for this machine (`silica-<NNNNNN>-<platform>`, lowest number when there
are several) into `~/.silica/bin/`, linking `silica-compiler` to it. Supported hosts: macOS on
Apple Silicon, Linux aarch64, Linux x86-64.

Set `SILICA_COMPILER=/path/to/silica-compiler` to use another compiler (for example
`silica/binaries/silica-compiler` from a checkout). `GITHUB_TOKEN` is used if set.

## What a build does

The same three stages as `project_makefiles/Makefile`:

1. **Compile.** A build folder, `<project>/.silica-build/<name>/`, mirrors the sources with
   symlinks, so the compiler's `.sams`/`.iface` output never lands in your source tree. The
   modules are written to `silica.config` in `use`-dependency order with the entry last, and
   `silica-compiler` is run there (re-run on exit 75/76, its between-units memory reclaim).
2. **Assemble** each `.sams` with `clang` (macOS) or `cc` (Linux).
3. **Link** with entry `main`, plus any archives listed in `silica.link`.

What gets compiled:

- **A file** — that file, plus sibling `.silica` files it `use`s (transitively). Its module
  name is its file name.
- **A folder** — every `.silica` file under it. The entry is `main.silica`, or the single
  top-level file that defines `fn main`.

## Library modules

A released compiler does not include the standard library sources (`Supervisor`, etc.). Point
`SILICA_STDLIB` at a folder of them — e.g. `silica/compiler/stdlib` — or copy them to
`~/.silica/stdlib`. Any `use X;` the project doesn't satisfy itself is resolved to the first
`X.silica` found under that folder.

## Exit status

`silica run` exits with the program's status. A Silica `main` that returns an atom exits with
that atom's index, so `:ok` is **2**, not 0.

## Development

```bash
tests/run.sh        # end-to-end tests against the installed compiler
```

CI (`.github/workflows/ci.yml`) runs `bash -n` and ShellCheck, then `tests/run.sh` on macOS
Apple Silicon, Linux aarch64 and Linux x86-64. Pushing a version tag publishes a release:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The release holds `silica-cli-<tag>.tar.gz` (with the tag stamped into `silica version`) and its
`.sha256`. Tags containing a hyphen (`v0.2.0-rc1`) are marked as pre-releases.
