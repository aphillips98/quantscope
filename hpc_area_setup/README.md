# hpc_area_setup

Herramienta genérica para construir e instalar [llama.cpp](https://github.com/ggml-org/llama.cpp) en un área personal de un clúster HPC. Produce una instalación por perfil de hardware y módulos Lua compatibles con Lmod o Environment Modules.

No necesita privilegios de administrador. Los compiladores, Git, CMake y CUDA normalmente los proporciona el clúster mediante módulos; el instalador los valida antes de iniciar una compilación y puede cargarlos con `--load-module`.

## Estructura instalada

Para un perfil `H100` con CUDA se generan:

```text
~/.local/programs/H100/llamacpp_cuda/
~/.local/modules/H100/llamacpp_cuda/1.lua
```

Para CPU, el paquete se denomina `llamacpp`. Esta convención generaliza los modulefiles existentes y evita rutas especiales por máquina.

## Requisitos

- Bash 4+
- `git`
- `cmake`
- Compilador C y C++ (`cc` y `c++`, o las variables `CC` y `CXX`)
- `nvcc` cuando se utiliza `--cuda`
- Una instalación funcional de Lmod o Environment Modules solo si se usa `--load-module` o se desea cargar el modulefile después

Carga los módulos requeridos en la sesión o indícalos al instalador. Por ejemplo:

```bash
module load gcc cmake git cuda/12.8
./install_llamacpp.sh build --profile H100 --cuda --cuda-architectures 90
```

También puede cargarlos el propio instalador:

```bash
./install_llamacpp.sh build --profile H100 --cuda \
  --cuda-architectures 90 \
  --load-module gcc --load-module cmake --load-module git --load-module cuda/12.8
```

## Uso

| Objetivo | Comando |
| --- | --- |
| Compilación CPU portable | `./install_llamacpp.sh build --profile CPU` |
| CPU optimizada para el nodo | `./install_llamacpp.sh build --profile EPYC --native` |
| Compilación CUDA | `./install_llamacpp.sh build --profile DGX --cuda --cuda-architectures "80;90"` |
| Reanudar tras un corte | `./install_llamacpp.sh continue --profile DGX --cuda` |
| Regenerar solo el módulo | `./install_llamacpp.sh module --profile DGX --cuda` |
| Desinstalar sin confirmación | `./install_llamacpp.sh uninstall --profile DGX --cuda --yes` |

`--profile` se determina, por orden, con `HPC_PROFILE`, `SLURM_JOB_PARTITION` y finalmente `default`. En clústeres con nombres de partición poco descriptivos, establece explícitamente `--profile` para que la ruta del módulo sea estable.

La compilación CPU es portable por defecto. Usa `--native` únicamente cuando el binario vaya a ejecutarse en nodos de la misma microarquitectura. Para CUDA, especificar `--cuda-architectures` minimiza el tiempo de compilación y produce binarios adecuados para las GPU objetivo, por ejemplo `70`, `80` o `90`.

Por defecto se sigue la rama `master` de `ggml-org/llama.cpp`. Para una instalación reproducible, fija una etiqueta o commit:

```bash
./install_llamacpp.sh build --profile CPU --ref b1234 --version 2026.09
```

## Cargar y comprobar

```bash
module use "$HOME/.local/modulefiles"
module load H100/llamacpp_cuda/1
llama-cli --version
llama-server --help
```

## tmux

`install_tmux.sh` descarga el tarball oficial de tmux, lo compila e instala junto a un módulo Lua. Requiere un compilador C, `make`, `tar`, `curl` o `wget`, además de las cabeceras y bibliotecas de `libevent` y `ncurses`. En un clúster, carga los módulos que proporcionen esas dependencias:

```bash
./install_tmux.sh build --version 3.5a \
  --load-module gcc --load-module libevent --load-module ncurses
```

La instalación predeterminada queda en `~/.local/programs/tmux/3.5a` y publica `~/.local/modules/tmux/3.5a.lua`. Registra la raíz una vez por sesión y carga tmux cuando se necesite una sesión persistente de compilación:

```bash
module use "$HOME/.local/modules"
module load tmux/3.5a
tmux new -s llamacpp-build
```

El módulo solo añade sus directorios `bin` y `share/man`; tmux no es una dependencia de llama.cpp y por ello `install_llamacpp.sh` no lo carga implícitamente.

El uso de modelos GGUF queda separado deliberadamente: el instalador deja disponibles los ejecutables de llama.cpp y no descarga decenas de gigabytes de modelos. El script vecino `../download_models.sh` puede conservarse para esa operación.

## Validación rápida

```bash
bash -n install_llamacpp.sh
bash -n install_tmux.sh
bash tests/smoke_test.sh
```
