#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} [--config FILE] [--models FILE] [--campaign FILE] [--hardware FILE]
       [--output-dir DIR] [--dry-run]

Submit one validated benchmark campaign using its named YAML hardware profile.
Set submission defaults in --config and scheduler resources in the hardware profile YAML.
EOF
}

CONFIG=""
MODELS=""
CAMPAIGN=""
HARDWARE=""
OUTPUT_DIR=""
DRY_RUN=0
while (($#)); do
  case "$1" in
    --config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
    --models) MODELS="${2:?--models requires a value}"; shift 2 ;;
    --campaign) CAMPAIGN="${2:?--campaign requires a value}"; shift 2 ;;
    --hardware) HARDWARE="${2:?--hardware requires a value}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# Any existing venv can validate and read the YAML; the job itself uses the profile's venv.
BOOT_PYTHON="${PYTHON:-}"
USER_PYTHON="$BOOT_PYTHON"
if [[ -z "$BOOT_PYTHON" ]]; then
  for candidate in "${ROOT_DIR}"/.venv/bin/python "${ROOT_DIR}"/.venv-*/bin/python; do
    [[ -x "$candidate" ]] && { BOOT_PYTHON="$candidate"; break; }
  done
fi
[[ -n "$BOOT_PYTHON" ]] || { echo "Error: no virtual environment found; run install_env.sh [--profile NAME]" >&2; exit 1; }
PYTHON="$BOOT_PYTHON"

if [[ -n "$CONFIG" ]]; then
  CONFIG_VALUES="$("$PYTHON" - "$CONFIG" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as config_file:
  config = yaml.safe_load(config_file) or {}
if not isinstance(config, dict):
  raise SystemExit("Error: submission config must be a YAML mapping")

for key in ("models", "campaign", "hardware", "output_dir"):
  value = config.get(key, "")
  if value is not None and not isinstance(value, str):
    raise SystemExit(f"Error: {key} in submission config must be a string")
  print(value or "")

dry_run = config.get("dry_run", False)
if not isinstance(dry_run, bool):
  raise SystemExit("Error: dry_run in submission config must be true or false")
print(int(dry_run))
PY
)"
  readarray -t CONFIG_VALUES_ARRAY <<< "$CONFIG_VALUES"
  [[ -n "$MODELS" ]] || MODELS="${CONFIG_VALUES_ARRAY[0]}"
  [[ -n "$CAMPAIGN" ]] || CAMPAIGN="${CONFIG_VALUES_ARRAY[1]}"
  [[ -n "$HARDWARE" ]] || HARDWARE="${CONFIG_VALUES_ARRAY[2]}"
  [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="${CONFIG_VALUES_ARRAY[3]}"
  ((DRY_RUN)) || DRY_RUN="${CONFIG_VALUES_ARRAY[4]}"
fi

OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/results}"
[[ -n "$MODELS" && -n "$CAMPAIGN" && -n "$HARDWARE" ]] || { usage >&2; exit 2; }
"$PYTHON" -m quantscope_bench.cli validate --models "$MODELS" --campaign "$CAMPAIGN" --hardware "$HARDWARE"

profile="$($PYTHON - "$CAMPAIGN" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["hardware_profile"])
PY
)"

readarray -t SLURM_ARGS < <("$PYTHON" - "$HARDWARE" "$profile" <<'PY'
import sys, yaml
document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
scheduler = document["profiles"][sys.argv[2]].get("scheduler", {})
for key, option in (("account", "--account"), ("partition", "--partition"), ("nodelist", "--nodelist"), ("qos", "--qos"), ("gres", "--gres"), ("gpus", "--gpus"), ("cpus_per_task", "--cpus-per-task"), ("memory", "--mem"), ("time", "--time")):
    if value := scheduler.get(key): print(f"{option}={value}")
PY
)

readarray -t MODULES < <("$PYTHON" - "$HARDWARE" "$profile" <<'PY'
import sys, yaml
document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for name in document["profiles"][sys.argv[2]].get("modules") or []: print(name)
PY
)

MODULE_ROOT="${MODULE_ROOT:-${HOME}/.local/modules}"
if [[ -z "$USER_PYTHON" && -x "${ROOT_DIR}/.venv-${profile}/bin/python" ]]; then
  PYTHON="${ROOT_DIR}/.venv-${profile}/bin/python"
fi
COMMAND=("$PYTHON" -m quantscope_bench.cli run --models "$MODELS" --campaign "$CAMPAIGN" --hardware "$HARDWARE" --output-dir "$OUTPUT_DIR")
JOB_SCRIPT=""
if ((${#MODULES[@]})); then
  JOB_SCRIPT="$(printf 'module use %q && module load' "$MODULE_ROOT")$(printf ' %q' "${MODULES[@]}") && "
fi
# Explicit src path: the editable-install .pth was not honored inside the job.
JOB_SCRIPT+="export PYTHONPATH=$(printf '%q' "${ROOT_DIR}/src"):\${PYTHONPATH:-} && ${COMMAND[*]}"
# Login shell so the Lmod 'module' function is initialized on the compute node.
WRAPPED="bash -lc $(printf '%q' "$JOB_SCRIPT")"
if ((DRY_RUN)); then
  printf 'sbatch'; printf ' %q' "${SLURM_ARGS[@]}" --wrap "$WRAPPED"; printf '\n'
  exit 0
fi
command -v sbatch >/dev/null || { echo 'Error: sbatch is unavailable' >&2; exit 1; }
sbatch "${SLURM_ARGS[@]}" --job-name="qscope-${profile}" --wrap "$WRAPPED"