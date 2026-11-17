![Silica](./assets/silica_icon_small.png)

# silica-cli

`silica` is the command line for [Silica](https://github.com/Silica-Language-and-Compiler/silica), a memory-safe, functional systems language. It builds and runs Silica programs with one command, with no Makefile to copy and no compiler to build. The first time you use it, it downloads the latest released compiler for your machine.

```bash
curl -fsSL https://github.com/Silica-Language-and-Compiler/silica-cli/releases/latest/download/install.sh | bash
```

```silica
fn main() -> atom {
    sequence proc[device_io]
        _: atom <- println("Hello, world!")
    produces
        pure :ok
    end
}
```

```console
$ silica run examples/hello-world
   Compiling hello-world (1 module) with silica-999921-macos-applesilicon
  Assembling hello-world
     Linking hello-world
    Finished examples/hello-world/.silica-build/hello-world/hello-world
     Running examples/hello-world/.silica-build/hello-world/hello-world
Hello, world!
```

- [Install](#install) on macOS (Apple Silicon), Linux on AArch64, or Linux on x86-64
- [Commands](#commands): `build`, `run`, `update`, `version`
- [Hosts and targets](#hosts-and-targets): `--host` and `--target`
- [What a build does](#what-a-build-does)
- [The specification](#the-specification), installed to `~/.silica/spec`; `silica spec` explains it to AI agents
- [Contributing and license](#contributing-and-license)
- [The Silica language](https://github.com/Silica-Language-and-Compiler/silica): [specification](https://github.com/Silica-Language-and-Compiler/silica/blob/main/compiler/design_documents/silica-specification.md), [tutorials](https://github.com/Silica-Language-and-Compiler/silica/tree/main/compiler/tutorials_and_howtos), [roadmap](https://github.com/Silica-Language-and-Compiler/silica/blob/main/ROADMAP.md)

---

![](./assets/silica_icon_emoji.png)**Motto: Secure by default at compile time — fail soft, never fail silent**

---

## Install

```bash
curl -fsSL https://github.com/Silica-Language-and-Compiler/silica-cli/releases/latest/download/install.sh | bash
```

The script:

1. downloads `silica-cli.tar.gz` from the latest release and checks its SHA-256
2. unpacks it into `~/.silica/cli` and links `~/.silica/bin/silica` to it
3. downloads the latest [Silica compiler release](https://github.com/Silica-Language-and-Compiler/silica/releases/latest) for this machine into `~/.silica/bin`
4. downloads that release's `silica-specification.zip` and unpacks it, flat, into `~/.silica/spec`
5. downloads the standard library sources from that release's tag (`compiler/stdlib`) into `~/.silica/stdlib`

Then add the command to your `PATH` (the script prints this line if it is missing):

```bash
export PATH="$HOME/.silica/bin:$PATH"
```

| Variable | Effect |
| -------- | ------ |
| `SILICA_CLI_VERSION=v0.1.0` | Install that release instead of the latest |
| `SILICA_HOME=/opt/silica` | Install somewhere other than `~/.silica` |
| `SILICA_NO_COMPILER=1` | Skip the compiler download; it then happens on first build |

```bash
curl -fsSL https://github.com/Silica-Language-and-Compiler/silica-cli/releases/latest/download/install.sh | SILICA_CLI_VERSION=v0.1.0 bash
```

**From a clone.** Running `./install.sh` inside a checkout links `~/.silica/bin/silica` to that checkout's `src/silica.sh`, so your edits take effect right away.

**Requirements.** You need `curl` and `tar`, plus `clang` on macOS (from the Xcode Command Line Tools) or `cc` on Linux, which assembles and links what the compiler emits. The released compilers run on macOS on Apple Silicon, Linux on AArch64 and Linux on x86-64.

To uninstall, delete `~/.silica`.

## Commands

```bash
silica build hello.silica        # compile, assemble and link an executable
silica run hello.silica          # build, then execute
silica run my_app/               # a project folder; main.silica is the entry point
silica run my_app -- arg1 arg2   # arguments after -- go to the program
silica build my_app -o bin/app   # choose where the executable goes
silica build my_app --target linux-aarch64   # generate code for another platform or a board
silica update                    # update every installed compiler, the specification and stdlib
silica spec                      # where the specification is and how to use it (for AI agents)
silica version                   # CLI version, compiler in use, platform
```

`-v` / `--verbose` shows the compiler's full output. Without it, a failed build prints only the diagnostic:

```console
$ silica build broken.silica
   Compiling broken (1 module) with silica-999921-macos-applesilicon
❌ Compilation error:
ModuleError error at
broken.silica
 line: 1
 column: 5
E1009

unknown module in use: Missing (spec 19.3)
See specification: spec:sect19.3

error: compilation failed (exit 1); full log: .silica-build/broken/compile.log
```

**What gets compiled.**

- **A file:** that file, plus any sibling `.silica` files it `use`s, directly or indirectly. A module's name is its file name.
- **A folder:** every `.silica` file under it. The entry point is `main.silica`, or the single top-level file that defines `fn main`.

**Exit status.** `silica run` exits with the program's own status. A Silica `main` that returns an atom exits with that atom's index, so `:ok` is **2**, not 0.

| Variable | Effect |
| -------- | ------ |
| `SILICA_COMPILER` | Use this compiler binary, for example `silica/binaries/silica-compiler` from a checkout |
| `SILICA_STDLIB` | A folder of library modules (default: `~/.silica/stdlib`, downloaded when first needed) |
| `SILICA_HOME` | Install root (default: `~/.silica`) |
| `GITHUB_TOKEN` | Raises the GitHub API rate limit for compiler downloads |

### Library modules

A released compiler ships without the standard library sources (`Supervisor`, `dangerous_tcp_carrier` and the rest). The CLI fetches them for you. `silica update` installs [`compiler/stdlib`](https://github.com/Silica-Language-and-Compiler/silica/tree/main/compiler/stdlib) from the release's tag into `~/.silica/stdlib`, and so does the first build that `use`s a module the project doesn't define. Only the sources are fetched: `.silica` modules, plus the `.meta` sidecars and C files of their FFI wrappers. Any `use X;` that the project doesn't satisfy itself resolves to the first `X.silica` under that folder.

To use a Silica checkout instead, point `SILICA_STDLIB` at its `compiler/stdlib`. A `~/.silica/stdlib` that the CLI did not install (one without `~/.silica/stdlib.release`) is never replaced.

### FFI wrappers

A `dangerous_*` module names its Fifi sidecar with `wrapper_meta "dangerous_exposure_source/..."`. Every `link_library` the sidecar declares needs a prebuilt archive at `dangerous_exposure_source/lib/lib<name>.a`. The build folder gets both:

- the project's own `dangerous_exposure_source/`, mirrored file by file;
- any sidecar the project doesn't provide, found by file name under the library folder. The standard library's socket wrappers (`dangerous_sockets`, used by the `(:tcp)`, `(:udp)` and `(:serial)` carriers) come from here;
- any missing archive, compiled from `<name>.c` beside its sidecar into the build folder, never into your sources.

So `silica run` works for a program that uses the standard library's carriers, with nothing to set up.

## Hosts and targets

A compiler has two platforms. Its **host** is the platform it runs on, and its **target** is the platform it generates code for. By default both are this machine. `build` and `run` accept:

| Option | Meaning |
| ------ | ------- |
| `--target <target>` | Generate code for `<target>`: a platform (`macos-applesilicon`, `linux-aarch64`, `linux-x86_64`) or a board (`ESP32_S3_raw`). The compiler repository's spellings work too (`linux_aarch64`, `apple_silicon_mac`, `ESP32-S3_raw`), and board names ignore case. |
| `--host <platform>` | Use a compiler that runs on `<platform>`. Only useful when this machine can run that platform's binaries, for example through emulation. |

```console
$ silica build my_app --target ESP32_S3_raw
no Silica compiler for ESP32_S3_raw (cross compiler on macos-applesilicon) in ~/.silica/bin; fetching the latest release
 Downloading silica-999955-ESP32_S3_raw-macos-applesilicon (compiler-72af851...)
   Installed ~/.silica/bin/silica-compiler-ESP32_S3_raw -> silica-999955-ESP32_S3_raw-macos-applesilicon
   Compiling my_app (1 module) for ESP32_S3_raw with silica-999955-ESP32_S3_raw-macos-applesilicon
    Finished my_app/.silica-build/ESP32_S3_raw/my_app (assembly for ESP32_S3_raw; ...)
```

- **The compiler is downloaded when missing.** A target other than the host's own needs a cross compiler, the release asset `silica-<NNNNNN>-<token>-<host>` (the token is the target's name in the compiler repository with `_` for `-`, for example `linux_aarch64` or `ESP32_S3_raw`). The first build for that target downloads it to `~/.silica/bin/silica-compiler-<token>`. If the latest release has no such compiler, the error lists the targets it does have for your host. `silica update --target <target>` installs one ahead of time.
- **`silica update` updates every installed compiler**: this machine's own, plus each cross compiler a build or `update --target` installed.
- **Output goes to a folder per target.** A target other than this machine builds into `<project>/.silica-build/<target>/<name>/`.
- **Another platform needs its own C toolchain.** Assembling and linking for a different platform uses `CC`, or the GNU cross compiler for that platform (`aarch64-linux-gnu-gcc`, `x86_64-linux-gnu-gcc`) when it is installed. Without either, the build stops and says which toolchain to set.
- **A board stops at assembly.** For a board target the build leaves the compiler's `.sams` output in the build folder, for the board's own toolchain to assemble, link and flash. `-o` does not apply, and `silica run` refuses a board target.
- **Running another platform's program.** `silica run --target <platform>` builds the program and then executes it. That only works where the OS can run that platform's binaries (for example Linux with `binfmt` and QEMU). Otherwise the CLI says to copy the executable to a machine of that platform.

## What a build does

A build runs the same three stages as the Silica repository's [project Makefiles](https://github.com/Silica-Language-and-Compiler/silica/tree/main/project_makefiles):

1. **Compile.** `<project>/.silica-build/<name>/` mirrors the sources through symlinks, so the compiler's `.sams` and `.iface` output never lands in your source tree. The modules are written to `silica.config` in `use`-dependency order with the entry last, and `silica-compiler` runs there. When the compiler exits 75 or 76 between units to reclaim memory, the CLI runs it again.
2. **Assemble** each `.sams` file with `clang` on macOS or `cc` on Linux.
3. **Link** with `main` as the entry point, plus any archives listed in `silica.link` by FFI wrappers.

Before stage 1, the CLI builds any missing FFI wrapper archives; see [FFI wrappers](#ffi-wrappers).

The compiler lives in `~/.silica/bin`. It is the `silica-<NNNNNN>-<platform>` asset from the [latest release](https://github.com/Silica-Language-and-Compiler/silica/releases/latest), and `silica-compiler` links to it. When a release has several, the CLI takes the lowest number, which is the newest compiler. Cross compilers sit beside it; see [Hosts and targets](#hosts-and-targets).

## The specification

The language specification ships with each compiler release as `silica-specification.zip`. Whenever the compiler is downloaded, on the first build or with `silica update`, the CLI also installs that release's specification into `~/.silica/spec`. It is one flat folder of Markdown files, with `silica-specification.md` as the entry point:

```
~/.silica/
├── bin/          silica, silica-compiler -> silica-<NNNNNN>-<platform>,
│                 silica-compiler-<token> -> silica-<NNNNNN>-<token>-<platform> (cross compilers)
├── spec/         silica-specification.md, silica_ffi_wrapper_specification.md, ROADMAP.md, ...
├── spec.release  the compiler release the specification came from
├── stdlib/       the standard library sources (compiler/stdlib at that release)
└── stdlib.release
```

`silica spec` prints plain-text instructions, written for AI coding agents, on using the specification. It gives the folder's absolute path, the documents to start with, and how to find a section from a compiler error (`spec:sect3.6.3` points to the heading `3.6.3`) or an error code (`E2008`). It also lists every document with its title. Point an agent at it, for example from `CLAUDE.md` or `AGENTS.md`:

```markdown
This project is written in Silica. Run `silica spec` before writing or changing Silica code,
and follow its instructions for reading the language specification.
```

`silica spec --path` prints only the folder. Both exit 1 when the specification is not installed.

The zip keeps the repository's folder layout, so links between the documents (`../../ROADMAP.md`) are rewritten to bare file names (`ROADMAP.md`) and still work in the flat folder. Links to documents the release does not include stay as they are. `silica update` replaces the folder only when a newer release is out. Unpacking uses `unzip`, falling back to `python3` or `bsdtar`. If none is available, or the download fails, the CLI prints a warning and builds still work.

## Development

```
silica-cli/
├── src/silica.sh   the CLI (bash 3.2-compatible, so it runs on stock macOS)
├── silica          launcher, so ./silica works from a clone
├── install.sh      the installer (release download, or link to a clone)
└── tests/run.sh    end-to-end tests against a real compiler
```

```bash
./silica run path/to/program.silica
tests/run.sh
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `bash -n` and ShellCheck on every push and pull request. It then runs `tests/run.sh` on macOS on Apple Silicon, Linux on AArch64 and Linux on x86-64.

**Releasing.** Every merge to `main` (or commit pushed straight to it) is released once the tests pass. Each release bumps the patch number of the newest `vX.Y.Z` tag, starting at `v0.1.0`. To move the minor or major number, push that tag yourself:

```bash
git tag v0.2.0 && git push origin v0.2.0   # released as v0.2.0; the next merge becomes v0.2.1
```

A release holds `silica-cli.tar.gz` (with the version stamped into `silica version`), its `.sha256`, and `install.sh`. The asset names carry no version, so the `releases/latest/download/install.sh` URL always points at the newest release. A tag you push with a hyphen, such as `v0.3.0-rc1`, is marked as a pre-release; `latest` skips it, and so does the version bump.

## Contributing and license

Issues and pull requests are welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md) and the [AI Policy](AI_POLICY.md) first.

silica-cli is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
