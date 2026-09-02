#!/bin/bash

set -Eeuo pipefail

# =============================================================================
# Helper functions
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

find_nsys_report() {
  local prefix="$1"

  if [[ -f "${prefix}.nsys-rep" ]]; then
    printf '%s\n' "${prefix}.nsys-rep"
    return 0
  fi

  if [[ -f "${prefix}.qdrep" ]]; then
    printf '%s\n' "${prefix}.qdrep"
    return 0
  fi

  return 1
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


# =============================================================================
# General configuration
# =============================================================================

JOB_NAME="${JOB_NAME:-llamacpp_DGX002_A100}"
JOB_ID="${SLURM_JOB_ID:-$$}"
NODE_NAME="$(hostname -s)"
NODE_KEY="${NODE_KEY:-DGX002_A100}"

OUTPUT_ROOT="${OUTPUT_ROOT:-/u/dssc/aphillips/dev/power_analysis/efimon_data}"
NODE_LOGDIR="${OUTPUT_ROOT}/${NODE_KEY}/logs"
RUNS_ROOT="${OUTPUT_ROOT}/${NODE_KEY}/runs"

PROMPT_PATH="${PROMPT_PATH:-/u/dssc/aphillips/dev/power_analysis/models/prompt.txt}"
MODEL_PATH="${MODEL_PATH:-/u/dssc/aphillips/dev/power_analysis/models/llm-models}"

# Execution mode:
#   both    = run the efimon phase and the Nsight phase (default)
#   efimon  = run only the efimon phase
#   profile = run only the Nsight phase
MODE="${MODE:-both}"

# Stabilization time between consecutive executions.
# This sleep is outside the efimon measurement window.
SLEEP_SECS="${SLEEP_SECS:-20}"

# Optional longer pause between the efimon and Nsight phases.
BETWEEN_PHASES_SLEEP="${BETWEEN_PHASES_SLEEP:-60}"

# Number of repetitions per model in each phase.
RUNS_PER_MODEL="${RUNS_PER_MODEL:-1}"

# Number of full end-to-end iterations of the whole process. Each iteration
# creates its own run directory and its own ZIP archive.
ITERATIONS="${ITERATIONS:-1}"

# Optional separate Nsight module.
# Example:
#   NSIGHT_MODULE="DGX/nsight-systems"
NSIGHT_MODULE="${NSIGHT_MODULE:-}"

# Nsight Systems settings.
NSYS_TRACE="${NSYS_TRACE:-cuda,nvtx,osrt}"
NSYS_SAMPLE="${NSYS_SAMPLE:-none}"
NSYS_CPUCTXSW="${NSYS_CPUCTXSW:-none}"
GENERATE_NSYS_STATS="${GENERATE_NSYS_STATS:-1}"

mkdir -p "$NODE_LOGDIR" "$RUNS_ROOT"


# =============================================================================
# Job identity and main job log
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
# Job information
# =============================================================================

echo
echo "============================================================================="
echo "JOB INFORMATION"
echo "============================================================================="
echo "JOB ID:                    $JOB_ID"
echo "JOB NAME:                  $JOB_NAME"
echo "NODE:                      $NODE_NAME"
echo "NODE KEY:                  $NODE_KEY"
echo "EXECUTION MODE:            $MODE"
echo "JOB RUN NAME:              $JOB_RUN_NAME"
echo "ITERATIONS:                $ITERATIONS"
echo "MAIN LOG:                  $LOGFILE"
echo "PROMPT PATH:               $PROMPT_PATH"
echo "MODEL DIRECTORY:           $MODEL_PATH"
echo "RUNS PER MODEL:            $RUNS_PER_MODEL"
echo "SLEEP BETWEEN RUNS:        ${SLEEP_SECS}s"
echo "SLEEP BETWEEN PHASES:      ${BETWEEN_PHASES_SLEEP}s"
echo "NSIGHT TRACE:              $NSYS_TRACE"
echo "NSIGHT SAMPLE:             $NSYS_SAMPLE"
echo "NSIGHT CPU CONTEXT SWITCH: $NSYS_CPUCTXSW"
echo "START TIME:                $(date '+%F %T')"
echo "============================================================================="
echo


# =============================================================================
# Validate numeric parameters
# =============================================================================

if ! [[ "$SLEEP_SECS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SLEEP_SECS must be a non-negative integer."
  exit 1
fi

if ! [[ "$BETWEEN_PHASES_SLEEP" =~ ^[0-9]+$ ]]; then
  echo "ERROR: BETWEEN_PHASES_SLEEP must be a non-negative integer."
  exit 1
fi

if ! [[ "$RUNS_PER_MODEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: RUNS_PER_MODEL must be a positive integer."
  exit 1
fi

if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: ITERATIONS must be a positive integer."
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
# Load modules
# =============================================================================

echo "Loading modules..."

run_cmd module use "$HOME/.local/modules"
run_cmd module load DGX/cuda
run_cmd module load DGX/llamacpp_cuda

if [[ -n "$NSIGHT_MODULE" ]]; then
  run_cmd module load "$NSIGHT_MODULE"
fi

echo
echo "Loaded modules:"
module list 2>&1 || true
echo


# =============================================================================
# Validate commands
# =============================================================================

REQUIRED_COMMANDS=(llama-cli efimon-launcher)

if [[ "$RUN_PROFILE" == "1" ]]; then
  REQUIRED_COMMANDS+=(nsys)
fi

for command_name in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: Required command was not found: $command_name"

    if [[ "$command_name" == "nsys" ]]; then
      echo "Try:"
      echo "  module spider nsight"
      echo "  module spider nsight-systems"
      echo
      echo "Or set:"
      echo '  export NSIGHT_MODULE="YOUR/NSIGHT/MODULE"'
    fi

    exit 1
  fi
done

echo "llama-cli:      $(command -v llama-cli)"
echo "efimon-launcher: $(command -v efimon-launcher)"
if [[ "$RUN_PROFILE" == "1" ]]; then
  echo "nsys:           $(command -v nsys)"
fi
echo

if [[ "$RUN_PROFILE" == "1" ]]; then
  run_cmd nsys --version
fi


# =============================================================================
# Validate efimon daemon
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
# Iterate the whole process
# =============================================================================

for ((ITERATION_INDEX = 1; ITERATION_INDEX <= ITERATIONS; ITERATION_INDEX++)); do

echo
echo "#############################################################################"
echo "STARTING ITERATION ${ITERATION_INDEX}/${ITERATIONS}"
echo "#############################################################################"


# =============================================================================
# Run directory (per iteration)
# =============================================================================

RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_NAME="${JOB_NAME}_${RUN_TIMESTAMP}_${JOB_ID}_iter${ITERATION_INDEX}"
RUN_DIR="${RUNS_ROOT}/${RUN_NAME}"

EFIMON_DIR="${RUN_DIR}/efimon"
NSIGHT_DIR="${RUN_DIR}/nsight"
NSIGHT_STATS_DIR="${RUN_DIR}/nsight_stats"
LLAMA_LOGDIR="${RUN_DIR}/llama_logs"
MANIFEST_DIR="${RUN_DIR}/manifests"
SYSTEM_INFO_DIR="${RUN_DIR}/system_info"

mkdir -p \
  "$RUN_DIR" \
  "$EFIMON_DIR" \
  "$NSIGHT_DIR" \
  "$NSIGHT_STATS_DIR" \
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
  echo "cuda_visible_devices=${CUDA_VISIBLE_DEVICES:-not_set}"
  echo "llama_cli=$(command -v llama-cli)"
  echo "efimon_launcher=$(command -v efimon-launcher)"
  echo "nsys=$(command -v nsys)"
  echo "nsys_version=$(nsys --version 2>&1 | tr '\n' ' ')"
  echo "prompt_path=$PROMPT_PATH"
  echo "model_path=$MODEL_PATH"
  echo "runs_per_model=$RUNS_PER_MODEL"
  echo "sleep_seconds=$SLEEP_SECS"
  echo "between_phases_sleep=$BETWEEN_PHASES_SLEEP"
  echo "nsys_trace=$NSYS_TRACE"
  echo "nsys_sample=$NSYS_SAMPLE"
  echo "nsys_cpuctxsw=$NSYS_CPUCTXSW"
} > "${SYSTEM_INFO_DIR}/run_metadata.txt"

module list > "${SYSTEM_INFO_DIR}/modules.txt" 2>&1 || true

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi > "${SYSTEM_INFO_DIR}/nvidia_smi.txt" 2>&1 || true

  nvidia-smi \
    --query-gpu=index,name,uuid,driver_version,memory.total,power.limit \
    --format=csv \
    > "${SYSTEM_INFO_DIR}/gpu_inventory.csv" 2>&1 || true
fi

if command -v lscpu >/dev/null 2>&1; then
  lscpu > "${SYSTEM_INFO_DIR}/lscpu.txt" 2>&1 || true
fi


# =============================================================================
# Initialize result counters
# =============================================================================

EFIMON_SUCCESS=0
EFIMON_FAILURE=0
NSIGHT_SUCCESS=0
NSIGHT_FAILURE=0


# =============================================================================
# PHASE 1: all efimon runs
# =============================================================================

if [[ "$RUN_EFIMON" == "1" ]]; then

echo
echo "#############################################################################"
echo "PHASE 1: BASELINE ENERGY MEASUREMENTS WITH EFIMON"
echo "#############################################################################"
echo
echo "Nsight Systems is NOT used during this phase."
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
      echo "Stabilizing for ${SLEEP_SECS}s before the measured execution..."
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

    START_EPOCH="$(date +%s)"

    set +e

    run_cmd efimon-launcher \
      --output "$EFIMON_OUTPUT" \
      -c "$EFIMON_COMMAND"

    EFIMON_EXIT_CODE=$?

    set -e

    END_EPOCH="$(date +%s)"
    DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

    if [[ "$EFIMON_EXIT_CODE" -eq 0 ]]; then
      EFIMON_SUCCESS=$((EFIMON_SUCCESS + 1))
      STATUS="success"
      echo "EFIMON RUN COMPLETED SUCCESSFULLY."
    else
      EFIMON_FAILURE=$((EFIMON_FAILURE + 1))
      STATUS="failure"
      echo "ERROR: efimon run failed with exit code $EFIMON_EXIT_CODE."
    fi

    {
      echo "phase=efimon"
      echo "status=$STATUS"
      echo "model_index=$MODEL_INDEX"
      echo "model_name=$MODEL_BASENAME"
      echo "model_path=$CURRENT_MODEL_PATH"
      echo "repetition=$REPETITION"
      echo "start_epoch=$START_EPOCH"
      echo "end_epoch=$END_EPOCH"
      echo "duration_seconds=$DURATION_SECONDS"
      echo "exit_code=$EFIMON_EXIT_CODE"
      echo "prompt_path=$PROMPT_PATH"
      echo "efimon_output=$EFIMON_OUTPUT"
      echo "llama_log=$LLAMA_LOG_OUTPUT"
      echo "command=$EFIMON_COMMAND"
    } > "$MANIFEST_OUTPUT"

    echo "END:               $(date '+%F %T')"
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
  echo "Waiting ${BETWEEN_PHASES_SLEEP}s before Nsight Systems profiling..."
  run_cmd sleep "$BETWEEN_PHASES_SLEEP"
fi


# =============================================================================
# PHASE 2: all Nsight Systems runs
# =============================================================================

echo
echo "#############################################################################"
echo "PHASE 2: NSIGHT SYSTEMS PROFILING"
echo "#############################################################################"
echo
echo "efimon is NOT used during this phase."
echo

if [[ "$RUN_PROFILE" != "1" ]]; then
  echo "Skipping Nsight phase (MODE=$MODE)."
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

    NSYS_OUTPUT_PREFIX="${NSIGHT_DIR}/nsys_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}"
    NSYS_PROFILE_LOG="${NSIGHT_STATS_DIR}/profile_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
    NSYS_STATS_OUTPUT="${NSIGHT_STATS_DIR}/stats_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"
    LLAMA_LOG_OUTPUT="${LLAMA_LOGDIR}/nsys_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.log"
    MANIFEST_OUTPUT="${MANIFEST_DIR}/nsys_${MODEL_SAFE_NAME}_rep${REP_LABEL}_${EXEC_TIMESTAMP}.txt"

    echo
    echo "-----------------------------------------------------------------------------"
    echo "NSIGHT MODEL:      ${MODEL_INDEX}/${#MODEL_PATHS[@]}"
    echo "REPETITION:        ${REPETITION}/${RUNS_PER_MODEL}"
    echo "MODEL NAME:        $MODEL_BASENAME"
    echo "MODEL PATH:        $CURRENT_MODEL_PATH"
    echo "NSYS PREFIX:       $NSYS_OUTPUT_PREFIX"
    echo "PROFILE LOG:       $NSYS_PROFILE_LOG"
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

    NSYS_CMD=(
      nsys profile
      --trace="$NSYS_TRACE"
      --sample="$NSYS_SAMPLE"
      --cpuctxsw="$NSYS_CPUCTXSW"
      --force-overwrite=true
      --stats=false
      --output="$NSYS_OUTPUT_PREFIX"
      env
      "LLAMA_ARG_LOG_FILE=$LLAMA_LOG_OUTPUT"
      "LLAMA_ARG_LOG_VERBOSITY=3"
      "${LLAMA_CMD[@]}"
    )

    NSYS_COMMAND="$(shell_join "${NSYS_CMD[@]}")"

    echo
    echo "Nsight command:"
    echo "$NSYS_COMMAND"
    echo

    START_EPOCH="$(date +%s)"

    set +e
    set +o pipefail

    "${NSYS_CMD[@]}" 2>&1 |
      tee "$NSYS_PROFILE_LOG"

    NSYS_EXIT_CODE="${PIPESTATUS[0]}"

    set -o pipefail
    set -e

    END_EPOCH="$(date +%s)"
    DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

    NSYS_REPORT=""

    if [[ "$NSYS_EXIT_CODE" -eq 0 ]] &&
       NSYS_REPORT="$(find_nsys_report "$NSYS_OUTPUT_PREFIX")"; then

      NSIGHT_SUCCESS=$((NSIGHT_SUCCESS + 1))
      STATUS="success"

      echo "NSIGHT REPORT:     $NSYS_REPORT"
      echo "NSIGHT RUN COMPLETED SUCCESSFULLY."

    else

      NSIGHT_FAILURE=$((NSIGHT_FAILURE + 1))
      STATUS="failure"

      echo "ERROR: Nsight run failed or did not generate a report."
      echo "EXIT CODE: $NSYS_EXIT_CODE"
    fi

    if [[ "$STATUS" == "success" ]] &&
       [[ "$GENERATE_NSYS_STATS" == "1" ]]; then

      echo
      echo "Generating Nsight textual statistics..."

      set +e

      nsys stats "$NSYS_REPORT" \
        > "$NSYS_STATS_OUTPUT" \
        2>&1

      STATS_EXIT_CODE=$?

      set -e

      if [[ "$STATS_EXIT_CODE" -eq 0 ]]; then
        echo "NSIGHT STATS:      $NSYS_STATS_OUTPUT"
      else
        echo "WARNING: nsys stats failed with exit code $STATS_EXIT_CODE."
        echo "Details: $NSYS_STATS_OUTPUT"
      fi

    else
      STATS_EXIT_CODE="not_run"
    fi

    {
      echo "phase=nsight"
      echo "status=$STATUS"
      echo "model_index=$MODEL_INDEX"
      echo "model_name=$MODEL_BASENAME"
      echo "model_path=$CURRENT_MODEL_PATH"
      echo "repetition=$REPETITION"
      echo "start_epoch=$START_EPOCH"
      echo "end_epoch=$END_EPOCH"
      echo "duration_seconds=$DURATION_SECONDS"
      echo "profile_exit_code=$NSYS_EXIT_CODE"
      echo "stats_exit_code=$STATS_EXIT_CODE"
      echo "prompt_path=$PROMPT_PATH"
      echo "nsys_output_prefix=$NSYS_OUTPUT_PREFIX"
      echo "nsys_report=$NSYS_REPORT"
      echo "nsys_profile_log=$NSYS_PROFILE_LOG"
      echo "nsys_stats=$NSYS_STATS_OUTPUT"
      echo "llama_log=$LLAMA_LOG_OUTPUT"
      echo "command=$NSYS_COMMAND"
    } > "$MANIFEST_OUTPUT"

    echo "END:               $(date '+%F %T')"
    echo "DURATION:          ${DURATION_SECONDS}s"
  done
done

echo
echo "============================================================================="
echo "PHASE 2 COMPLETED"
echo "============================================================================="
echo "Successful Nsight runs: $NSIGHT_SUCCESS"
echo "Failed Nsight runs:     $NSIGHT_FAILURE"
echo "Completion time:        $(date '+%F %T')"
echo "============================================================================="

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
  echo "expected_runs_per_phase=$((${#MODEL_PATHS[@]} * RUNS_PER_MODEL))"
  echo "efimon_success=$EFIMON_SUCCESS"
  echo "efimon_failure=$EFIMON_FAILURE"
  echo "nsight_success=$NSIGHT_SUCCESS"
  echo "nsight_failure=$NSIGHT_FAILURE"
  echo "run_directory=$RUN_DIR"
  echo "main_log=$LOGFILE"
  echo "error_log=$ERRLOG"
} > "$SUMMARY_FILE"


# =============================================================================
# Create ZIP archive
# =============================================================================

echo
echo "#############################################################################"
echo "CREATING FINAL ARCHIVE"
echo "#############################################################################"

ARCHIVE_PATH="${RUNS_ROOT}/${RUN_NAME}.zip"

if command -v zip >/dev/null 2>&1; then

  (
    cd "$RUNS_ROOT"

    run_cmd zip \
      -r \
      -q \
      "${RUN_NAME}.zip" \
      "$RUN_NAME"
  )

else

  echo "ERROR: zip command was not found."
  echo "Unable to create the requested ZIP archive."
  exit 1
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "ERROR: ZIP archive was not created: $ARCHIVE_PATH"
  exit 1
fi

ARCHIVE_COPY="${OUTPUT_ROOT}/${RUN_NAME}.zip"

run_cmd cp \
  "$ARCHIVE_PATH" \
  "$ARCHIVE_COPY"

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
echo "END TIME:                 $(date '+%F %T')"
echo "RUN DIRECTORY:            $RUN_DIR"
echo "ZIP ARCHIVE:              $ARCHIVE_PATH"
echo "ZIP COPY:                 $ARCHIVE_COPY"
echo "EFIMON SUCCESS/FAILURE:   ${EFIMON_SUCCESS}/${EFIMON_FAILURE}"
echo "NSIGHT SUCCESS/FAILURE:   ${NSIGHT_SUCCESS}/${NSIGHT_FAILURE}"
echo "SUMMARY:                  $SUMMARY_FILE"
echo "ERROR LOG:                $ERRLOG"
echo "============================================================================="

done


# =============================================================================
# All iterations completed
# =============================================================================

echo
echo "#############################################################################"
echo "ALL ITERATIONS COMPLETED"
echo "#############################################################################"
echo "TOTAL ITERATIONS:         $ITERATIONS"
echo "END TIME:                 $(date '+%F %T')"
echo "MAIN LOG:                 $LOGFILE"
echo "#############################################################################"