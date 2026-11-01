# model_check

Sanity check mínimo para verificar que los modelos GGUF responden bien a MMLU y
HellaSwag **sin pasar por el harness de `llm_benchmarks`**. Usa los benchmarks
oficiales de DeepEval ([MMLU](https://deepeval.com/docs/benchmarks-mmlu) y
[HellaSwag](https://deepeval.com/docs/benchmarks-hellaswag)): arranca
`llama-server` con el GGUF local, lo envuelve en un `DeepEvalBaseLLM` y ejecuta
`benchmark.evaluate(...)`, mostrando además la respuesta cruda del modelo en
cada pregunta.

Si aquí los modelos puntúan claramente por encima del 25% aleatorio pero el
benchmark completo reporta 0.0, el problema está en el pipeline
(adapter/runner), no en los modelos.

## Uso

Necesita `llama-server` en el `PATH` y un Python con `deepeval` (sirve el venv
del benchmark). Los modelos son ficheros `.gguf` locales; DeepEval carga las
preguntas desde su caché de datasets (ya presente en `~/.cache/huggingface`).

```bash
module use ~/.local/modules
module load cuda A100/llamacpp_cuda/py035   # o el perfil que toque

cd model_check
../llm_benchmarks/.venv-a100/bin/python check_models.py --models /ruta/al/modelo.gguf
```

Sin `--models` evalúa los cuatro modelos q4_k_m leyendo sus rutas de
`llm_benchmarks/orfeo_configs/models.yml`. Cada entrada de `--models` puede ser
una ruta a un `.gguf` local o un nombre definido en ese YAML.

Por defecto ejecuta `MMLUTask.HIGH_SCHOOL_COMPUTER_SCIENCE` (100 preguntas) y
`HellaSwagTask.APPLYING_SUNSCREEN` (20 preguntas) con 5-shot, igual que la
campaña `a100`.

Opciones útiles:

```bash
# otras tareas, o saltarse un benchmark
python check_models.py --mmlu-task astronomy --hellaswag-task none

# más tokens para ver la salida cruda completa
python check_models.py --max-tokens 32

# en CPU (sin GPU asignada) es el default; forzar GPU completa:
python check_models.py --gpu-layers -1
```

Salida: una línea por pregunta con `expected`, `got` (letra parseada) y el
texto crudo del modelo, el `overall_score` de DeepEval por modelo/benchmark, y
el detalle completo en `check_results.csv`.
