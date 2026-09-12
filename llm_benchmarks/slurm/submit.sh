#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: ${PROGRAM_NAME} --models FILE --campaign FILE --hardware FILE [--output-dir DIR] [--dry-run]

Submit one validated benchmark campaign using its named YAML hardware profile.
Set account, partition, QoS, module names, and resource limits in the profile YAML.
EOF
}

MODELS=""
CAMPAIGN=""
HARDWARE=""
OUTPUT_DIR="${ROOT_DIR}/results"
DRY_RUN=0
while (($#)); do
  case "$1" in
    --models) MODELS="${2:?--models requires a value}"; shift 2 ;;
    --campaign) CAMPAIGN="${2:?--campaign requires a value}"; shift 2 ;;
    --hardware) HARDWARE="${2:?--hardware requires a value}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$MODELS" && -n "$CAMPAIGN" && -n "$HARDWARE" ]] || { usage >&2; exit 2; }

PYTHON="${PYTHON:-${ROOT_DIR}/.venv/bin/python}"
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

COMMAND=("$PYTHON" -m quantscope_bench.cli run --models "$MODELS" --campaign "$CAMPAIGN" --hardware "$HARDWARE" --output-dir "$OUTPUT_DIR")
if ((DRY_RUN)); then
  printf 'sbatch'; printf ' %q' "${SLURM_ARGS[@]}" --wrap "${COMMAND[*]}"; printf '\n'
  exit 0
fi
command -v sbatch >/dev/null || { echo 'Error: sbatch is unavailable' >&2; exit 1; }
sbatch "${SLURM_ARGS[@]}" --job-name="qscope-${profile}" --wrap "${COMMAND[*]}"