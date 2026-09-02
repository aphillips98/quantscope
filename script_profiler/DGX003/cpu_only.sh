#!/bin/bash

set -Eeuo pipefail

# =============================================================================
# Utility functions
# =============================================================================

run_cmd() {
  printf '[%s] CMD:' "$(date '+%F %T')"
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

shell_join() {
  local joined
  printf -v joined '%q ' "$@"
  printf '%s' "${joined% }"
}

sanitize_name() {
  printf '%s' "$1" |
    tr '/[:space:]' '__' |
    tr -cd '[:alnum:]_.-'
}

log_error() {
  local exit_code="${1:-1}"
  local line_no="${2:-unknown}"
  local command="${3:-unknown}"

  printf '[%s] ERROR (exit %s) at line %s: %s\n' \
    "$(date '+%F %T')" \
    "$exit_code" \
    "$line_no" \
    "$command" >> "$ERRLOG"
}

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: $name must be a positive integer. Received: $value"
    exit 1
  fi
}

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name must be a non-negative integer. Received: $value"
    exit 1
  fi
}

# Check whether a perf event can be requested on the current node.
perf_event_available() {
  local event_name="$1"

  perf stat \
    --no-big-num \
    -e "$event_name" \
    -- true >/dev/null 2>&1
}


# =============================================================================
# General configuration
# =============================================================================

JOB_NAME="${JOB_NAME:-llamacpp_DGX003_CPU}"
JOB_ID="${SLURM_JOB_ID:-$$}"
NODE_NAME="$(hostname -s)"

NODE_KEY="${NODE_KEY:-DGX003_CPU}"

OUTPUT_ROOT="${OUTPUT_ROOT:-/u/dssc/aphillips/dev/power_analysis/efimon_data}"
NODE_LOGDIR="${OUTPUT_ROOT}/${NODE_KEY}/logs"
RUNS_ROOT="${OUTPUT_ROOT}/${NODE_KEY}/runs"

PROMPT_PATH="${PROMPT_PATH:-/u/dssc/aphillips/dev/power_analysis/models/prompt.txt}"
MODEL_PATH="${MODEL_PATH:-/u/dssc/aphillips/dev/power_analysis/models/llm-models}"

# Execution mode:
#   both    = run the efimon phase and the perf phase (default)
#   efimon  = run only the efimon phase
#   profile = run only the perf phase
MODE="${MODE:-both}"

# Number of repetitions for efimon and perf stat.
RUNS_PER_MODEL="${RUNS_PER_MODEL:-1}"

# Number of full end-to-end iterations of the whole process. Each iteration
# creates its own run directory and its own ZIP archive.
ITERATIONS="${ITERATIONS:-1}"

# Stabilization period before each execution.
# This sleep is outside the measured workload.
SLEEP_SECS="${SLEEP_SECS:-20}"

# Pause after completing all efimon runs and before starting perf.
BETWEEN_PHASES_SLEEP="${BETWEEN_PHASES_SLEEP:-60}"

# Optional module containing perf.
# Leave empty when perf is already available.
PERF_MODULE="${PERF_MODULE:-}"

# Run optional perf record phase:
#   0 = disabled
#   1 = enabled
ENABLE_PERF_RECORD="${ENABLE_PERF_RECORD:-0}"

# Number of perf record repetitions per model.
PERF_RECORD_RUNS="${PERF_RECORD_RUNS:-1}"

# Sampling frequency for perf record.
PERF_RECORD_FREQ="${PERF_RECORD_FREQ:-99}"

# Call-graph collection mode.
# Common choices:
#   dwarf
#   fp
#   lbr
PERF_CALL_GRAPH="${PERF_CALL_GRAPH:-dwarf}"

mkdir -p "$NODE_LOGDIR" "$RUNS_ROOT"


# =============================================================================
# Job identity and main execution log
# =============================================================================

JOB_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
JOB_RUN_NAME="${JOB_NAME}_${JOB_TIMESTAMP}_${JOB_ID}"

LOGFILE="${NODE_LOGDIR}/${JOB_RUN_NAME}.out"
exec > >(tee -a "$LOGFILE") 2>&1

# The error log starts at the node level so the ERR trap works during the
# one-time setup, before any per-iteration run directory exists. It is
# repointed to each iteration's run directory inside the loop.
ERRLOG="${NODE_LOGDIR}/${JOB_RUN_NAME}_errors.log"
touch "$ERRLOG"

trap 'log_error "$?" "$LINENO" "$BASH_COMMAND"' ERR


# =============================================================================
# Initial information
# =============================================================================

echo
echo "============================================================================="
echo "JOB INFORMATION"
echo "============================================================================="
echo "JOB ID:                 $JOB_ID"
echo "JOB NAME:               $JOB_NAME"
echo "NODE:                   $NODE_NAME"
echo "NODE KEY:               $NODE_KEY"
echo "EXECUTION MODE:         $MODE"
echo "JOB RUN NAME:           $JOB_RUN_NAME"
echo "ITERATIONS:             $ITERATIONS"
echo "MAIN LOG:               $LOGFILE"
echo "PROMPT PATH:            $PROMPT_PATH"
echo "MODEL DIRECTORY:        $MODEL_PATH"
echo "RUNS PER MODEL:         $RUNS_PER_MODEL"
echo "SLEEP BETWEEN RUNS:     ${SLEEP_SECS}s"
echo "SLEEP BETWEEN PHASES:   ${BETWEEN_PHASES_SLEEP}s"
echo "PERF RECORD ENABLED:    $ENABLE_PERF_RECORD"
echo "PERF RECORD RUNS:       $PERF_RECORD_RUNS"
echo "PERF RECORD FREQUENCY:  $PERF_RECORD_FREQ"
echo "PERF CALL GRAPH:        $PERF_CALL_GRAPH"
echo "START TIME:             $(date '+%F %T')"
echo "============================================================================="
echo


# =============================================================================
# Validate parameters
# =============================================================================

validate_positive_integer "RUNS_PER_MODEL" "$RUNS_PER_MODEL"
validate_positive_integer "ITERATIONS" "$ITERATIONS"
validate_positive_integer "PERF_RECORD_RUNS" "$PERF_RECORD_RUNS"
validate_positive_integer "PERF_RECORD_FREQ" "$PERF_RECORD_FREQ"

validate_non_negative_integer "SLEEP_SECS" "$SLEEP_SECS"
validate_non_negative_integer "BETWEEN_PHASES_SLEEP" "$BETWEEN_PHASES_SLEEP"

if [[ "$ENABLE_PERF_RECORD" != "0" && "$ENABLE_PERF_RECORD" != "1" ]]; then
  echo "ERROR: ENABLE_PERF_RECORD must be 0 or 1."
  exit 1
fi

RUN_EFIMON=0
RUN_PROFILE=0

case "$MODE" in
  both)
    RUN_EFIMON=1
    RUN_PROFILE=1
    ;;
  efimon)
    RUN_EFIMON=1
    ;;
  profile)
    RUN_PROFILE=1
    ;;
  *)
    echo "ERROR: MODE must be one of: both, efimon, profile. Received: $MODE"
    exit 1
    ;;
esac


# =============================================================================
# Validate input paths
# =============================================================================

if [[ ! -f "$PROMPT_PATH" ]]; then
  echo "ERROR: Prompt file does not exist: $PROMPT_PATH"
  exit 1
fi

if [[ ! -r "$PROMPT_PATH" ]]; then
  echo "ERROR: Prompt file is not readable: $PROMPT_PATH"
  exit 1
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "ERROR: Model directory does not exist: $MODEL_PATH"
  exit 1
fi


# =============================================================================
# Load environment modules
# =============================================================================

echo "Loading modules..."

run_cmd module use "$HOME/.local/modules"
run_cmd module load H100/llamacpp

if [[ -n "$PERF_MODULE" ]]; then
  run_cmd module load "$PERF_MODULE"
fi

echo
echo "Loaded modules:"
module list 2>&1 || true
echo


# =============================================================================
# Validate required commands
# =============================================================================

REQUIRED_COMMANDS=(llama-cli efimon-launcher zip)

if [[ "$RUN_PROFILE" == "1" ]]; then
  REQUIRED_COMMANDS+=(perf)
fi

for command_name in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: Required command was not found: $command_name"

    if [[ "$command_name" == "perf" ]]; then
      echo
      echo "Check whether perf is available through an environment module:"
      echo "  module spider perf"
      echo
      echo "You can then run this script with:"
      echo '  PERF_MODULE="module/name" ./run_llamacpp_cpu.sh'
    fi

    exit 1
  fi
done

echo "llama-cli:       $(command -v llama-cli)"
echo "efimon-launcher: $(command -v efimon-launcher)"
if [[ "$RUN_PROFILE" == "1" ]]; then
  echo "perf:            $(command -v perf)"
fi
echo "zip:             $(command -v zip)"
echo

if [[ "$RUN_PROFILE" == "1" ]]; then
  run_cmd perf --version
fi


# =============================================================================
# Validate efimon
# =============================================================================

echo
echo "Checking efimon daemon..."

if command -v systemctl >/dev/null 2>&1 &&
   systemctl is-active --quiet efimon.service; then

  echo "efimon.service is active."

elif pgrep -x efimon-daemon >/dev/null 2>&1; then

  echo "efimon-daemon process is running."

else

  echo "ERROR: efimon service or daemon is not running."
  echo "Start efimon before launching this script."
  exit 1
fi


# =============================================================================
# Validate basic perf access
# =============================================================================

if [[ "$RUN_PROFILE" == "1" ]]; then
  echo
  echo "Checking perf access..."

  set +e

  PERF_ACCESS_TEST="$(
    perf stat \
      --no-big-num \
      -e task-clock \
      -- true 2>&1
  )"

  PERF_ACCESS_EXIT_CODE=$?

  set -e

  if [[ "$PERF_ACCESS_EXIT_CODE" -ne 0 ]]; then
    echo "ERROR: perf cannot access the required counters."
    echo
    echo "$PERF_ACCESS_TEST"
    echo
    echo "Possible causes:"
    echo "  - perf_event_paranoid is too restrictive."
    echo "  - The perf binary does not match the running kernel."
    echo "  - The cluster requires a dedicated perf module."
    echo "  - Hardware performance counters are disabled for users."
    exit 1
  fi

  echo "Basic perf access is available."
else
  echo
  echo "Skipping perf access check (MODE=$MODE)."
fi


# =============================================================================
# Discover models
# =============================================================================

declare -a MODEL_PATHS=()

while IFS= read -r -d '' model_file; do
  MODEL_PATHS+=("$model_file")
done < <(
  find "$MODEL_PATH" \
    -type f \
    -name '*.gguf' \
    -print0 |
  sort -z
)

if [[ ${#MODEL_PATHS[@]} -eq 0 ]]; then
  echo "ERROR: No GGUF models were found in: $MODEL_PATH"
  exit 1
fi

echo
echo "============================================================================="
echo "DISCOVERED MODELS"
echo "============================================================================="
echo "TOTAL MODELS: ${#MODEL_PATHS[@]}"

for model_file in "${MODEL_PATHS[@]}"; do
  echo " - $model_file"
done

echo "============================================================================="


# =============================================================================
# Select available perf events
# =============================================================================

# The script tests every event independently because some counters may not be
# exposed by every processor, virtualized node or cluster configuration.

REQUESTED_PERF_EVENTS=(
  # General
  task-clock
  cpu-clock
  cycles
  instructions
  branches
  branch-misses
  context-switches
  cpu-migrations
  page-faults

  # Aggregate last-level cache (generic)
  cache-references
  cache-misses

  # L1 data cache
  L1-dcache-loads
  L1-dcache-load-misses
  L1-dcache-stores

  # L1 instruction cache
  L1-icache-loads
  L1-icache-load-misses

  # L2 cache (AMD Zen named events)
  l2_cache_accesses_from_dc_misses
  l2_cache_misses_from_dc_misses

  # L2 cache (Intel named events)
  l2_rqsts.references
  l2_rqsts.miss

  # L3 / last-level cache (per-level, generic)
  LLC-loads
  LLC-load-misses
  LLC-stores
  LLC-store-misses
)

declare -a AVAILABLE_PERF_EVENTS=()
declare -a UNAVAILABLE_PERF_EVENTS=()
PERF_EVENTS_CSV="not_collected"

if [[ "$RUN_PROFILE" == "1" ]]; then
  echo
  echo "Checking requested perf events..."

  for event_name in "${REQUESTED_PERF_EVENTS[@]}"; do
    if perf_event_available "$event_name"; then
      AVAILABLE_PERF_EVENTS+=("$event_name")
      echo "  AVAILABLE:   $event_name"
    else
      UNAVAILABLE_PERF_EVENTS+=("$event_name")
      echo "  UNAVAILABLE: $event_name"
    fi
  done

  if [[ ${#AVAILABLE_PERF_EVENTS[@]} -eq 0 ]]; then
    echo "ERROR: None of the requested perf events are available."
    exit 1
  fi

  PERF_EVENTS_CSV="$(
    IFS=,
    printf '%s' "${AVAILABLE_PERF_EVENTS[*]}"
  )"

  echo
  echo "Events selected for perf stat:"
  echo "  $PERF_EVENTS_CSV"
else
  echo
  echo "Skipping perf event selection (MODE=$MODE)."
fi


# =============================================================================
# Iterate the whole process
# =============================================================================

for ((ITERATION_INDEX = 1; ITERATION_INDEX <= ITERATIONS; ITERATION_INDEX++)); do

echo
echo "#############################################################################"
echo "STARTING ITERATION ${ITERATION_INDEX}/${ITERATIONS}"
echo "#############################################################################"


# =============================================================================
# Run directories (per iteration)
# =============================================================================

RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_NAME="${JOB_NAME}_${RUN_TIMESTAMP}_${JOB_ID}_iter${ITERATION_INDEX}"
RUN_DIR="${RUNS_ROOT}/${RUN_NAME}"

EFIMON_DIR="${RUN_DIR}/efimon"
PERF_STAT_DIR="${RUN_DIR}/perf_stat"
PERF_RECORD_DIR="${RUN_DIR}/perf_record"
PERF_REPORT_DIR="${RUN_DIR}/perf_reports"
LLAMA_LOGDIR="${RUN_DIR}/llama_logs"
MANIFEST_DIR="${RUN_DIR}/manifests"
SYSTEM_INFO_DIR="${RUN_DIR}/system_info"

mkdir -p \
  "$RUN_DIR" \
  "$EFIMON_DIR" \
  "$PERF_STAT_DIR" \
  "$PERF_RECORD_DIR" \
  "$PERF_REPORT_DIR" \
  "$LLAMA_LOGDIR" \
  "$MANIFEST_DIR" \
  "$SYSTEM_INFO_DIR"

# Repoint the error log to this iteration's run directory. The trap reads
# $ERRLOG dynamically, so subsequent errors are recorded per iteration.
ERRLOG="${RUN_DIR}/errors.log"
touch "$ERRLOG"

echo "RUN NAME:      $RUN_NAME"
echo "RUN DIRECTORY: $RUN_DIR"


# =============================================================================
# Save system information
# =============================================================================

{
  echo "date=$(date --iso-8601=seconds)"
  echo "hostname=$(hostname)"
  echo "hostname_short=$NODE_NAME"
  echo "kernel=$(uname -a)"
  echo "job_id=$JOB_ID"
  echo "slurm_job_id=${SLURM_JOB_ID:-not_available}"
  echo "slurm_job_name=${SLURM_JOB_NAME:-not_available}"
  echo "llama_cli=$(command -v llama-cli)"
  echo "efimon_launcher=$(command -v efimon-launcher)"
  echo "perf=$(command -v perf)"
  echo "perf_version=$(perf --version 2>&1)"
  echo "prompt_path=$PROMPT_PATH"
  echo "model_directory=$MODEL_PATH"
  echo "runs_per_model=$RUNS_PER_MODEL"
  echo "sleep_seconds=$SLEEP_SECS"
  echo "between_phases_sleep=$BETWEEN_PHASES_SLEEP"
  echo "enable_perf_record=$ENABLE_PERF_RECORD"
  echo "perf_record_runs=$PERF_RECORD_RUNS"
  echo "perf_record_frequency=$PERF_RECORD_FREQ"
  echo "perf_call_graph=$PERF_CALL_GRAPH"
  echo "perf_events=$PERF_EVENTS_CSV"
} > "${SYSTEM_INFO_DIR}/run_metadata.txt"

if [[ ${#AVAILABLE_PERF_EVENTS[@]} -gt 0 ]]; then
  printf '%s\n' "${AVAILABLE_PERF_EVENTS[@]}" \
    > "${SYSTEM_INFO_DIR}/available_perf_events.txt"
else
  : > "${SYSTEM_INFO_DIR}/available_perf_events.txt"
fi

if [[ ${#UNAVAILABLE_PERF_EVENTS[@]} -gt 0 ]]; then
  printf '%s\n' "${UNAVAILABLE_PERF_EVENTS[@]}" \
    > "${SYSTEM_INFO_DIR}/unavailable_perf_events.txt"
else
  : > "${SYSTEM_INFO_DIR}/unavailable_perf_events.txt"
fi

module list > "${SYSTEM_INFO_DIR}/modules.txt" 2>&1 || true
perf list > "${SYSTEM_INFO_DIR}/perf_list.txt" 2>&1 || true

# Reading perf_event_paranoid is optional metadata. A failure here must never
# abort the experiment or trigger the global ERR trap.
PERF_PARANOID_FILE="${SYSTEM_INFO_DIR}/perf_event_paranoid.txt"

{
  if command -v timeout >/dev/null 2>&1; then
    if command -v sysctl >/dev/null 2>&1; then
      if ! timeout 5 sysctl kernel.perf_event_paranoid; then
        echo "unavailable"
      fi
    elif [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
      if ! timeout 5 cat /proc/sys/kernel/perf_event_paranoid; then
        echo "unavailable"
      fi
    else
      echo "unavailable"
    fi
  else
    if command -v sysctl >/dev/null 2>&1; then
      if ! sysctl kernel.perf_event_paranoid; then
        echo "unavailable"
      fi
    elif [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
      if ! cat /proc/sys/kernel/perf_event_paranoid; then
        echo "unavailable"
      fi
    else
      echo "unavailable"
    fi
  fi
} > "$PERF_PARANOID_FILE" 2>&1 || {
  echo "WARNING: Unable to collect kernel.perf_event_paranoid metadata."
  echo "unavailable" > "$PERF_PARANOID_FILE"
}

if command -v lscpu >/dev/null 2>&1; then
  lscpu > "${SYSTEM_INFO_DIR}/lscpu.txt" 2>&1 || true
fi

if command -v numactl >/dev/null 2>&1; then
  numactl --hardware \
    > "${SYSTEM_INFO_DIR}/numa_hardware.txt" 2>&1 || true
fi

if command -v free >/dev/null 2>&1; then
  free -h > "${SYSTEM_INFO_DIR}/memory.txt" 2>&1 || true
fi


# =============================================================================
# Initialize result counters
# =============================================================================

EFIMON_SUCCESS=0
EFIMON_FAILURE=0
PERF_STAT_SUCCESS=0
PERF_STAT_FAILURE=0
PERF_RECORD_SUCCESS=0
PERF_RECORD_FAILURE=0


# =============================================================================
# Phase 1: all efimon executions
# =============================================================================

if [[ "$RUN_EFIMON" == "1" ]]; then

echo
echo "#############################################################################"
echo "PHASE 1: BASELINE ENERGY MEASUREMENTS WITH EFIMON"
echo "#############################################################################"
echo
echo "perf is NOT used during this phase."
echo

MODEL_INDEX=0

for CURRENT_MODEL_PATH in "${MODEL_PATHS[@]}"; do
  MODEL_INDEX=$((MODEL_INDEX + 1))

  MODEL_BASENAME="$(basename "$CURRENT_MODEL_PATH")"
  MODEL_STEM="${MODEL_BASENAME%.gguf}"
  MODEL_SAFE_NAME="$(sanitize_name "$MODEL_STEM")"

  for ((REPETITION = 1; REPETITION <= RUNS_PER_MODEL; REPETITION++)); do
    EXEC_TIMESTAMP="$(date +%Y%m%d_%H%M%S_%N | cut -c1-21)"
    REP_LABEL="$(printf '%02d' "$REPETITION")"

    EFIMON_OUTPUT="${EFIMON_DIR}/efimon_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.csv"
    LLAMA_LOG_OUTPUT="${LLAMA_LOGDIR}/efimon_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
    MANIFEST_OUTPUT="${MANIFEST_DIR}/efimon_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"

    echo
    echo "-----------------------------------------------------------------------------"
    echo "EFIMON MODEL:      ${MODEL_INDEX}/${#MODEL_PATHS[@]}"
    echo "REPETITION:        ${REPETITION}/${RUNS_PER_MODEL}"
    echo "MODEL NAME:        $MODEL_BASENAME"
    echo "MODEL PATH:        $CURRENT_MODEL_PATH"
    echo "EFIMON OUTPUT:     $EFIMON_OUTPUT"
    echo "LLAMA LOG:         $LLAMA_LOG_OUTPUT"
    echo "START:             $(date '+%F %T')"
    echo "-----------------------------------------------------------------------------"

    if (( SLEEP_SECS > 0 )); then
      echo "Stabilizing for ${SLEEP_SECS}s before measurement..."
      run_cmd sleep "$SLEEP_SECS"
    fi

    LLAMA_CMD=(
      llama-cli
      -f "$PROMPT_PATH"
      --no-display-prompt
      --single-turn
      --model "$CURRENT_MODEL_PATH"
    )

    EFIMON_WORKLOAD=(
      env
      "LLAMA_ARG_LOG_FILE=$LLAMA_LOG_OUTPUT"
      "LLAMA_ARG_LOG_VERBOSITY=3"
      "${LLAMA_CMD[@]}"
    )

    EFIMON_COMMAND="$(shell_join "${EFIMON_WORKLOAD[@]}")"

    START_TIME_ISO="$(date --iso-8601=seconds)"
    START_EPOCH="$(date +%s)"

    set +e

    efimon-launcher \
      --output "$EFIMON_OUTPUT" \
      -c "$EFIMON_COMMAND"

    EFIMON_EXIT_CODE=$?

    set -e

    END_EPOCH="$(date +%s)"
    END_TIME_ISO="$(date --iso-8601=seconds)"
    DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

    if [[ "$EFIMON_EXIT_CODE" -eq 0 ]]; then
      STATUS="success"
      EFIMON_SUCCESS=$((EFIMON_SUCCESS + 1))
      echo "EFIMON RUN COMPLETED SUCCESSFULLY."
    else
      STATUS="failure"
      EFIMON_FAILURE=$((EFIMON_FAILURE + 1))
      echo "ERROR: efimon run failed with exit code $EFIMON_EXIT_CODE."
    fi

    {
      echo "phase=efimon"
      echo "status=$STATUS"
      echo "model_index=$MODEL_INDEX"
      echo "model_name=$MODEL_BASENAME"
      echo "model_path=$CURRENT_MODEL_PATH"
      echo "repetition=$REPETITION"
      echo "start_time=$START_TIME_ISO"
      echo "end_time=$END_TIME_ISO"
      echo "duration_seconds=$DURATION_SECONDS"
      echo "exit_code=$EFIMON_EXIT_CODE"
      echo "prompt_path=$PROMPT_PATH"
      echo "efimon_output=$EFIMON_OUTPUT"
      echo "llama_log=$LLAMA_LOG_OUTPUT"
      echo "command=$EFIMON_COMMAND"
    } > "$MANIFEST_OUTPUT"

    echo "END:               $END_TIME_ISO"
    echo "DURATION:          ${DURATION_SECONDS}s"
  done
done

echo
echo "============================================================================="
echo "PHASE 1 COMPLETED"
echo "============================================================================="
echo "Successful efimon runs: $EFIMON_SUCCESS"
echo "Failed efimon runs:     $EFIMON_FAILURE"
echo "Completion time:        $(date '+%F %T')"
echo "============================================================================="

else
  echo
  echo "Skipping efimon phase (MODE=$MODE)."
fi


# =============================================================================
# Pause between phases
# =============================================================================

if [[ "$RUN_EFIMON" == "1" && "$RUN_PROFILE" == "1" && "$BETWEEN_PHASES_SLEEP" -gt 0 ]]; then
  echo
  echo "Waiting ${BETWEEN_PHASES_SLEEP}s before starting perf stat..."
  run_cmd sleep "$BETWEEN_PHASES_SLEEP"
fi


# =============================================================================
# Phase 2: all perf stat executions
# =============================================================================

echo
echo "#############################################################################"
echo "PHASE 2: CPU PROFILING WITH PERF STAT"
echo "#############################################################################"
echo
echo "efimon is NOT used during this phase."
echo

if [[ "$RUN_PROFILE" != "1" ]]; then
  echo "Skipping perf stat phase (MODE=$MODE)."
fi

if [[ "$RUN_PROFILE" == "1" ]]; then

MODEL_INDEX=0

for CURRENT_MODEL_PATH in "${MODEL_PATHS[@]}"; do
  MODEL_INDEX=$((MODEL_INDEX + 1))

  MODEL_BASENAME="$(basename "$CURRENT_MODEL_PATH")"
  MODEL_STEM="${MODEL_BASENAME%.gguf}"
  MODEL_SAFE_NAME="$(sanitize_name "$MODEL_STEM")"

  for ((REPETITION = 1; REPETITION <= RUNS_PER_MODEL; REPETITION++)); do
    EXEC_TIMESTAMP="$(date +%Y%m%d_%H%M%S_%N | cut -c1-21)"
    REP_LABEL="$(printf '%02d' "$REPETITION")"

    PERF_STAT_OUTPUT="${PERF_STAT_DIR}/perf_stat_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.csv"
    PERF_CONSOLE_LOG="${PERF_STAT_DIR}/perf_console_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
    LLAMA_LOG_OUTPUT="${LLAMA_LOGDIR}/perf_stat_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
    MANIFEST_OUTPUT="${MANIFEST_DIR}/perf_stat_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"

    echo
    echo "-----------------------------------------------------------------------------"
    echo "PERF STAT MODEL:   ${MODEL_INDEX}/${#MODEL_PATHS[@]}"
    echo "REPETITION:        ${REPETITION}/${RUNS_PER_MODEL}"
    echo "MODEL NAME:        $MODEL_BASENAME"
    echo "MODEL PATH:        $CURRENT_MODEL_PATH"
    echo "PERF OUTPUT:       $PERF_STAT_OUTPUT"
    echo "CONSOLE LOG:       $PERF_CONSOLE_LOG"
    echo "LLAMA LOG:         $LLAMA_LOG_OUTPUT"
    echo "START:             $(date '+%F %T')"
    echo "-----------------------------------------------------------------------------"

    if (( SLEEP_SECS > 0 )); then
      echo "Stabilizing for ${SLEEP_SECS}s before profiling..."
      run_cmd sleep "$SLEEP_SECS"
    fi

    LLAMA_CMD=(
      llama-cli
      -f "$PROMPT_PATH"
      --no-display-prompt
      --single-turn
      --model "$CURRENT_MODEL_PATH"
    )

    PERF_CMD=(
      perf stat
      --no-big-num
      -x ","
      -o "$PERF_STAT_OUTPUT"
      -e "$PERF_EVENTS_CSV"
      --
      env
      "LLAMA_ARG_LOG_FILE=$LLAMA_LOG_OUTPUT"
      "LLAMA_ARG_LOG_VERBOSITY=3"
      "${LLAMA_CMD[@]}"
    )

    PERF_COMMAND="$(shell_join "${PERF_CMD[@]}")"

    echo
    echo "Perf command:"
    echo "$PERF_COMMAND"
    echo

    START_TIME_ISO="$(date --iso-8601=seconds)"
    START_EPOCH="$(date +%s)"

    set +e
    set +o pipefail

    "${PERF_CMD[@]}" 2>&1 |
      tee "$PERF_CONSOLE_LOG"

    PERF_EXIT_CODE="${PIPESTATUS[0]}"

    set -o pipefail
    set -e

    END_EPOCH="$(date +%s)"
    END_TIME_ISO="$(date --iso-8601=seconds)"
    DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

    if [[ "$PERF_EXIT_CODE" -eq 0 && -s "$PERF_STAT_OUTPUT" ]]; then
      STATUS="success"
      PERF_STAT_SUCCESS=$((PERF_STAT_SUCCESS + 1))
      echo "PERF STAT RUN COMPLETED SUCCESSFULLY."
    else
      STATUS="failure"
      PERF_STAT_FAILURE=$((PERF_STAT_FAILURE + 1))
      echo "ERROR: perf stat failed with exit code $PERF_EXIT_CODE."
    fi

    {
      echo "phase=perf_stat"
      echo "status=$STATUS"
      echo "model_index=$MODEL_INDEX"
      echo "model_name=$MODEL_BASENAME"
      echo "model_path=$CURRENT_MODEL_PATH"
      echo "repetition=$REPETITION"
      echo "start_time=$START_TIME_ISO"
      echo "end_time=$END_TIME_ISO"
      echo "duration_seconds=$DURATION_SECONDS"
      echo "exit_code=$PERF_EXIT_CODE"
      echo "prompt_path=$PROMPT_PATH"
      echo "perf_events=$PERF_EVENTS_CSV"
      echo "perf_stat_output=$PERF_STAT_OUTPUT"
      echo "perf_console_log=$PERF_CONSOLE_LOG"
      echo "llama_log=$LLAMA_LOG_OUTPUT"
      echo "command=$PERF_COMMAND"
    } > "$MANIFEST_OUTPUT"

    echo "END:               $END_TIME_ISO"
    echo "DURATION:          ${DURATION_SECONDS}s"
  done
done

echo
echo "============================================================================="
echo "PHASE 2 COMPLETED"
echo "============================================================================="
echo "Successful perf stat runs: $PERF_STAT_SUCCESS"
echo "Failed perf stat runs:     $PERF_STAT_FAILURE"
echo "Completion time:           $(date '+%F %T')"
echo "============================================================================="

fi


# =============================================================================
# Phase 3: optional perf record
# =============================================================================

if [[ "$RUN_PROFILE" == "1" && "$ENABLE_PERF_RECORD" == "1" ]]; then
  echo
  echo "#############################################################################"
  echo "PHASE 3: FUNCTION-LEVEL PROFILING WITH PERF RECORD"
  echo "#############################################################################"
  echo
  echo "This phase can generate significantly larger output files."
  echo

  if (( BETWEEN_PHASES_SLEEP > 0 )); then
    echo "Waiting ${BETWEEN_PHASES_SLEEP}s before starting perf record..."
    run_cmd sleep "$BETWEEN_PHASES_SLEEP"
  fi

  MODEL_INDEX=0

  for CURRENT_MODEL_PATH in "${MODEL_PATHS[@]}"; do
    MODEL_INDEX=$((MODEL_INDEX + 1))

    MODEL_BASENAME="$(basename "$CURRENT_MODEL_PATH")"
    MODEL_STEM="${MODEL_BASENAME%.gguf}"
    MODEL_SAFE_NAME="$(sanitize_name "$MODEL_STEM")"

    for ((REPETITION = 1; REPETITION <= PERF_RECORD_RUNS; REPETITION++)); do
      EXEC_TIMESTAMP="$(date +%Y%m%d_%H%M%S_%N | cut -c1-21)"
      REP_LABEL="$(printf '%02d' "$REPETITION")"

      PERF_DATA_OUTPUT="${PERF_RECORD_DIR}/perf_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.data"
      PERF_RECORD_LOG="${PERF_RECORD_DIR}/record_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
      PERF_REPORT_OUTPUT="${PERF_REPORT_DIR}/report_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"
      LLAMA_LOG_OUTPUT="${LLAMA_LOGDIR}/perf_record_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
      MANIFEST_OUTPUT="${MANIFEST_DIR}/perf_record_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"

      echo
      echo "-----------------------------------------------------------------------------"
      echo "PERF RECORD MODEL: ${MODEL_INDEX}/${#MODEL_PATHS[@]}"
      echo "REPETITION:        ${REPETITION}/${PERF_RECORD_RUNS}"
      echo "MODEL NAME:        $MODEL_BASENAME"
      echo "PERF DATA:         $PERF_DATA_OUTPUT"
      echo "PERF REPORT:       $PERF_REPORT_OUTPUT"
      echo "START:             $(date '+%F %T')"
      echo "-----------------------------------------------------------------------------"

      if (( SLEEP_SECS > 0 )); then
        echo "Stabilizing for ${SLEEP_SECS}s before profiling..."
        run_cmd sleep "$SLEEP_SECS"
      fi

      LLAMA_CMD=(
        llama-cli
        -f "$PROMPT_PATH"
        --no-display-prompt
        --single-turn
        --model "$CURRENT_MODEL_PATH"
      )

      PERF_RECORD_CMD=(
        perf record
        -F "$PERF_RECORD_FREQ"
        --call-graph "$PERF_CALL_GRAPH"
        -o "$PERF_DATA_OUTPUT"
        --
        env
        "LLAMA_ARG_LOG_FILE=$LLAMA_LOG_OUTPUT"
        "LLAMA_ARG_LOG_VERBOSITY=3"
        "${LLAMA_CMD[@]}"
      )

      PERF_RECORD_COMMAND="$(shell_join "${PERF_RECORD_CMD[@]}")"

      START_TIME_ISO="$(date --iso-8601=seconds)"
      START_EPOCH="$(date +%s)"

      set +e
      set +o pipefail

      "${PERF_RECORD_CMD[@]}" 2>&1 |
        tee "$PERF_RECORD_LOG"

      PERF_RECORD_EXIT_CODE="${PIPESTATUS[0]}"

      set -o pipefail
      set -e

      END_EPOCH="$(date +%s)"
      END_TIME_ISO="$(date --iso-8601=seconds)"
      DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

      PERF_REPORT_EXIT_CODE="not_run"

      if [[ "$PERF_RECORD_EXIT_CODE" -eq 0 && -s "$PERF_DATA_OUTPUT" ]]; then
        STATUS="success"
        PERF_RECORD_SUCCESS=$((PERF_RECORD_SUCCESS + 1))

        set +e

        perf report \
          --stdio \
          --sort comm,dso,symbol \
          -i "$PERF_DATA_OUTPUT" \
          > "$PERF_REPORT_OUTPUT" \
          2>&1

        PERF_REPORT_EXIT_CODE=$?

        set -e

        if [[ "$PERF_REPORT_EXIT_CODE" -ne 0 ]]; then
          echo "WARNING: perf report failed with exit code $PERF_REPORT_EXIT_CODE."
        fi
      else
        STATUS="failure"
        PERF_RECORD_FAILURE=$((PERF_RECORD_FAILURE + 1))
        echo "ERROR: perf record failed with exit code $PERF_RECORD_EXIT_CODE."
      fi

      {
        echo "phase=perf_record"
        echo "status=$STATUS"
        echo "model_index=$MODEL_INDEX"
        echo "model_name=$MODEL_BASENAME"
        echo "model_path=$CURRENT_MODEL_PATH"
        echo "repetition=$REPETITION"
        echo "start_time=$START_TIME_ISO"
        echo "end_time=$END_TIME_ISO"
        echo "duration_seconds=$DURATION_SECONDS"
        echo "record_exit_code=$PERF_RECORD_EXIT_CODE"
        echo "report_exit_code=$PERF_REPORT_EXIT_CODE"
        echo "perf_data=$PERF_DATA_OUTPUT"
        echo "perf_record_log=$PERF_RECORD_LOG"
        echo "perf_report=$PERF_REPORT_OUTPUT"
        echo "llama_log=$LLAMA_LOG_OUTPUT"
        echo "command=$PERF_RECORD_COMMAND"
      } > "$MANIFEST_OUTPUT"
    done
  done

  echo
  echo "============================================================================="
  echo "PHASE 3 COMPLETED"
  echo "============================================================================="
  echo "Successful perf record runs: $PERF_RECORD_SUCCESS"
  echo "Failed perf record runs:     $PERF_RECORD_FAILURE"
  echo "============================================================================="
else
  echo
  echo "Optional perf record phase is disabled."
fi


# =============================================================================
# Final execution summary
# =============================================================================

SUMMARY_FILE="${RUN_DIR}/execution_summary.txt"

{
  echo "run_name=$RUN_NAME"
  echo "job_id=$JOB_ID"
  echo "node=$NODE_NAME"
  echo "end_time=$(date --iso-8601=seconds)"
  echo "models=${#MODEL_PATHS[@]}"
  echo "runs_per_model=$RUNS_PER_MODEL"
  echo "expected_efimon_runs=$((${#MODEL_PATHS[@]} * RUNS_PER_MODEL))"
  echo "expected_perf_stat_runs=$((${#MODEL_PATHS[@]} * RUNS_PER_MODEL))"
  echo "efimon_success=$EFIMON_SUCCESS"
  echo "efimon_failure=$EFIMON_FAILURE"
  echo "perf_stat_success=$PERF_STAT_SUCCESS"
  echo "perf_stat_failure=$PERF_STAT_FAILURE"
  echo "perf_record_enabled=$ENABLE_PERF_RECORD"
  echo "perf_record_success=$PERF_RECORD_SUCCESS"
  echo "perf_record_failure=$PERF_RECORD_FAILURE"
  echo "perf_events=$PERF_EVENTS_CSV"
  echo "run_directory=$RUN_DIR"
  echo "main_log=$LOGFILE"
  echo "error_log=$ERRLOG"
} > "$SUMMARY_FILE"


# =============================================================================
# Copy main log into run directory
# =============================================================================

cp "$LOGFILE" "${RUN_DIR}/main_job.log"


# =============================================================================
# Create final ZIP archive
# =============================================================================

echo
echo "#############################################################################"
echo "CREATING FINAL ZIP ARCHIVE"
echo "#############################################################################"

ARCHIVE_PATH="${RUNS_ROOT}/${RUN_NAME}.zip"
ARCHIVE_COPY="${OUTPUT_ROOT}/${RUN_NAME}.zip"

(
  cd "$RUNS_ROOT"

  run_cmd zip \
    -r \
    -q \
    "${RUN_NAME}.zip" \
    "$RUN_NAME"
)

if [[ ! -s "$ARCHIVE_PATH" ]]; then
  echo "ERROR: ZIP archive was not created correctly:"
  echo "  $ARCHIVE_PATH"
  exit 1
fi

run_cmd cp "$ARCHIVE_PATH" "$ARCHIVE_COPY"

echo
echo "Archive created:"
echo "  $ARCHIVE_PATH"
echo
echo "Archive copied to:"
echo "  $ARCHIVE_COPY"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_PATH" |
    tee "${ARCHIVE_PATH}.sha256"

  cp \
    "${ARCHIVE_PATH}.sha256" \
    "${ARCHIVE_COPY}.sha256"
fi


# =============================================================================
# Iteration completed
# =============================================================================

echo
echo "============================================================================="
echo "ITERATION ${ITERATION_INDEX}/${ITERATIONS} COMPLETED"
echo "============================================================================="
echo "END TIME:                   $(date '+%F %T')"
echo "RUN DIRECTORY:              $RUN_DIR"
echo "ZIP ARCHIVE:                $ARCHIVE_PATH"
echo "ZIP COPY:                   $ARCHIVE_COPY"
echo "EFIMON SUCCESS/FAILURE:     ${EFIMON_SUCCESS}/${EFIMON_FAILURE}"
echo "PERF STAT SUCCESS/FAILURE:  ${PERF_STAT_SUCCESS}/${PERF_STAT_FAILURE}"
echo "PERF RECORD ENABLED:        $ENABLE_PERF_RECORD"
echo "PERF RECORD SUCCESS/FAILURE:${PERF_RECORD_SUCCESS}/${PERF_RECORD_FAILURE}"
echo "SUMMARY:                    $SUMMARY_FILE"
echo "ERROR LOG:                  $ERRLOG"
echo "============================================================================="

done


# =============================================================================
# All iterations completed
# =============================================================================

echo
echo "#############################################################################"
echo "ALL ITERATIONS COMPLETED"
echo "#############################################################################"
echo "TOTAL ITERATIONS:           $ITERATIONS"
echo "END TIME:                   $(date '+%F %T')"
echo "MAIN LOG:                   $LOGFILE"
echo "#############################################################################"
