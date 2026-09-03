# hpc_area_setup

Generic tool to build and install [llama.cpp](https://github.com/ggml-org/llama.cpp) in a personal area of an HPC cluster. It produces one installation per hardware profile and Lua modulefiles compatible with Lmod or Environment Modules.

No administrator privileges are required. Compilers, Git, CMake and CUDA are usually provided by the cluster via modules; the installer validates them before starting a build and can load them with `--load-module`.

## Installed structure

For an `H100` profile with CUDA, the following are generated:

```text
~/.local/programs/H100/llamacpp_cuda/
~/.local/modules/H100/llamacpp_cuda/1.lua
```

For CPU, the package is named `llamacpp`. This convention generalizes the existing modulefiles and avoids machine-specific paths.

## Requirements

- Bash 4+
- `git`
- `cmake`
- C and C++ compiler (`cc` and `c++`, or the `CC` and `CXX` variables)
- `nvcc` when using `--cuda`
- A working Lmod or Environment Modules installation only if using `--load-module` or if you want to load the modulefile afterwards

Load the required modules in the session or pass them to the installer. For example:

```bash
module load gcc cmake git cuda/12.8
./install_llamacpp.sh build --profile H100 --cuda --cuda-architectures 90
```

The installer can also load them itself:

```bash
./install_llamacpp.sh build --profile H100 --cuda \
  --cuda-architectures 90 \
  --load-module gcc --load-module cmake --load-module git --load-module cuda/12.8
```

## Usage

| Goal | Command |
| --- | --- |
| Portable CPU build | `./install_llamacpp.sh build --profile CPU` |
| Node-optimized CPU build | `./install_llamacpp.sh build --profile EPYC --native` |
| CUDA build | `./install_llamacpp.sh build --profile DGX --cuda --cuda-architectures "80;90"` |
| Resume after an interruption | `./install_llamacpp.sh continue --profile DGX --cuda` |
| Regenerate only the module | `./install_llamacpp.sh module --profile DGX --cuda` |
| Uninstall without confirmation | `./install_llamacpp.sh uninstall --profile DGX --cuda --yes` |

`--profile` is determined, in order, by `HPC_PROFILE`, `SLURM_JOB_PARTITION` and finally `default`. On clusters with uninformative partition names, set `--profile` explicitly so the module path stays stable.

The CPU build is portable by default. Use `--native` only when the binary will run on nodes with the same microarchitecture. For CUDA, specifying `--cuda-architectures` minimizes build time and produces binaries suited to the target GPUs, e.g. `70`, `80` or `90`.

By default, the `master` branch of `ggml-org/llama.cpp` is used. For a reproducible installation, pin a tag or commit:

```bash
./install_llamacpp.sh build --profile CPU --ref b1234 --version 2026.09
```

## Load and verify

```bash
module use "$HOME/.local/modulefiles"
module load H100/llamacpp_cuda/1
llama-cli --version
llama-server --help
```

## tmux

`install_tmux.sh` downloads the official tmux tarball, builds it and installs it along with a Lua module. It requires a C compiler, `make`, `tar`, `curl` or `wget`, plus the headers and libraries for `libevent` and `ncurses`. On a cluster, load the modules that provide those dependencies:

```bash
./install_tmux.sh build --version 3.5a \
  --load-module gcc --load-module libevent --load-module ncurses
```

The default installation is placed at `~/.local/programs/tmux/3.5a` and publishes `~/.local/modules/tmux/3.5a.lua`. Register the root once per session and load tmux when a persistent build session is needed:

```bash
module use "$HOME/.local/modules"
module load tmux/3.5a
tmux new -s llamacpp-build
```

The module only adds its `bin` and `share/man` directories; tmux is not a dependency of llama.cpp, so `install_llamacpp.sh` does not load it implicitly.

Usage of GGUF models is deliberately kept separate: the installer only makes the llama.cpp executables available and does not download tens of gigabytes of models. The neighboring script `../download_models.sh` can be kept for that operation.

## Quick validation

```bash
bash -n install_llamacpp.sh
bash -n install_tmux.sh
bash tests/smoke_test.sh
```
