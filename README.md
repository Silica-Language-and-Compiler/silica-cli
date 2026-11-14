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
- [What a build does](#what-a-build-does)
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
silica update                    # fetch the newest released compiler
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
| `SILICA_STDLIB` | A folder of library modules (default: `~/.silica/stdlib`, if it exists) |
| `SILICA_HOME` | Install root (default: `~/.silica`) |
| `GITHUB_TOKEN` | Raises the GitHub API rate limit for compiler downloads |

### Library modules

A released compiler ships without the standard library sources (`Supervisor` and the rest). To use them, point `SILICA_STDLIB` at [`compiler/stdlib`](https://github.com/Silica-Language-and-Compiler/silica/tree/main/compiler/stdlib) in a Silica checkout, or copy that folder to `~/.silica/stdlib`. Any `use X;` that the project doesn't satisfy itself resolves to the first `X.silica` under that folder.

## What a build does

A build runs the same three stages as the Silica repository's [project Makefiles](https://github.com/Silica-Language-and-Compiler/silica/tree/main/project_makefiles):

1. **Compile.** `<project>/.silica-build/<name>/` mirrors the sources through symlinks, so the compiler's `.sams` and `.iface` output never lands in your source tree. The modules are written to `silica.config` in `use`-dependency order with the entry last, and `silica-compiler` runs there. When the compiler exits 75 or 76 between units to reclaim memory, the CLI runs it again.
2. **Assemble** each `.sams` file with `clang` on macOS or `cc` on Linux.
3. **Link** with `main` as the entry point, plus any archives listed in `silica.link` by FFI wrappers.

The compiler lives in `~/.silica/bin`. It is the `silica-<NNNNNN>-<platform>` asset from the [latest release](https://github.com/Silica-Language-and-Compiler/silica/releases/latest), and `silica-compiler` links to it. When a release has several, the CLI takes the lowest number, which is the newest compiler.

## Development

```
silica-cli/
├── src/silica.sh   the CLI (bash 3.2-compatible, so it runs on stock macOS)
├── silica          launcher, so ./silica works from a clone
├── install.sh      the installer (release download, or link to a clone)
├── examples/       sample programs
└── tests/run.sh    end-to-end tests against a real compiler
```

```bash
./silica run examples/hello-world
tests/run.sh
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `bash -n` and ShellCheck on every push and pull request. It then runs `tests/run.sh` on macOS on Apple Silicon, Linux on AArch64 and Linux on x86-64.

**Releasing.** Push a version tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Once the tests pass, the workflow publishes `silica-cli.tar.gz` (with the tag stamped into `silica version`), its `.sha256`, and `install.sh` as release assets. The asset names carry no version, so the `releases/latest/download/install.sh` URL always points at the newest release. A tag with a hyphen, such as `v0.2.0-rc1`, is marked as a pre-release, and `latest` skips it.

## Contributing and license

Issues and pull requests are welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md) and the [AI Policy](AI_POLICY.md) first.

silica-cli is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE).
