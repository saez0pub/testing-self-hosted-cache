#!/usr/bin/env bash
set -e -o pipefail
cd "$(dirname "$0")"

export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/cache-server-ca.crt
export RUNNER_GRACEFUL_STOP_TIMEOUT=${RUNNER_GRACEFUL_STOP_TIMEOUT:-300}
RUNNER_STOP_WAIT_TIME_SECONDS_BEFORE_CHECKING_RUNNING_JOB_TWICE=${RUNNER_STOP_WAIT_TIME_SECONDS_BEFORE_CHECKING_RUNNING_JOB_TWICE:-10}
RUNNER_GROUP="${RUNNER_GROUP:-self-hosted}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64}"
ATTACH=""
WAIT_REGISTRATION_FILE="/runner/.wait_registration"

touch "${WAIT_REGISTRATION_FILE}"

trap 'term_handler INT' INT
trap 'term_handler USR1' USR1
trap 'term_handler TERM' TERM

function term_handler() {
  echo "Stop signal handler for ${1} started"
  start_kill=$(now)
  i=0
  echo "Waiting for the runner to register first."
  while ! [ -f /runner/.runner ] && [ -f "${WAIT_REGISTRATION_FILE}" ]; do
    sleep 1
  done
  echo "Observed that the runner has been registered."
  while [ $(($(now) - start_kill)) -le "$RUNNER_GRACEFUL_STOP_TIMEOUT" ]; do
    if ps -p "${run_pid}" >/dev/null; then
      echo "Waiting ${RUNNER_STOP_WAIT_TIME_SECONDS_BEFORE_CHECKING_RUNNING_JOB_TWICE} seconds before checking again if a job is running"
      sleep "${RUNNER_STOP_WAIT_TIME_SECONDS_BEFORE_CHECKING_RUNNING_JOB_TWICE}"
      echo "stopping runner ${run_pid}"
      cd /runner
      ./config.sh remove --token "${RUNNER_TOKEN}"
      cd - >/dev/null
    else
      echo "Runner stopped"
      rm "${WAIT_REGISTRATION_FILE}" 2>/dev/null || true
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "Stop signal handler finished"
}

function now() {
  date +%s
}

start_docker() {
  if [ -f /var/run/docker.pid ]; then
    if ! ps -p "$(cat /var/run/docker.pid)" >/dev/null 2>&1; then
      echo "Found /var/run/docker.pid ($(cat /var/run/docker.pid) but no process linked to it, removing."
      sudo rm /var/run/docker.pid
    else
      echo "An instance of dockerd is already running, there is a problem, please fix it"
    fi
  fi
  echo 'Starting Docker daemon'
  sudo /usr/bin/dockerd --log-level=error &

  echo 'Waiting for processes to be running...'
  processes=(dockerd)

  for process in "${processes[@]}"; do
    if ! wait_for_process "$process"; then
      echo "$process is not running after max time"
      exit 1
    else
      echo "$process is running"
    fi
  done

  echo 'Docker started'
}

setup_cache_ca() {
  cp "${CACHE_CA_CERT_PATH}" "${NODE_EXTRA_CA_CERTS}"
  sudo update-ca-certificates
}

check_env() {
  if [ -z "${NODE_EXTRA_CA_CERTS}" ]; then
    echo "missing NODE_EXTRA_CA_CERTS env variable"
    exit 1
  fi
  if [ -z "${CACHE_CA_CERT_PATH}" ]; then
    echo "missing CACHE_CA_CERT_PATH env variable"
    exit 1
  fi
  if [ ! -e "${CACHE_CA_CERT_PATH}" ]; then
    echo "missing ${CACHE_CA_CERT_PATH}"
    exit 1
  fi

  if [ -z "${RUNNER_NAME}" ]; then
    echo 'RUNNER_NAME must be set'
    exit 1
  fi

  if [ -z "${RUNNER_TOKEN}" ]; then
    echo 'RUNNER_TOKEN must be set'
    exit 1
  fi

  if [ -n "${RUNNER_ORG}" ] && [ -n "${RUNNER_REPO}" ] && [ -n "${RUNNER_ENTERPRISE}" ]; then
    ATTACH="${RUNNER_ORG}/${RUNNER_REPO}"
  elif [ -n "${RUNNER_ORG}" ]; then
    ATTACH="${RUNNER_ORG}"
  elif [ -n "${RUNNER_REPO}" ]; then
    ATTACH="${RUNNER_REPO}"
  elif [ -n "${RUNNER_ENTERPRISE}" ]; then
    ATTACH="enterprises/${RUNNER_ENTERPRISE}"
  else
    echo 'At least one of RUNNER_ORG, RUNNER_REPO, or RUNNER_ENTERPRISE must be set'
    exit 1
  fi
  echo "Using env ${ATTACH} for RUNNER ${RUNNER_NAME}"
}

configure_runner() {
  echo "Registering runner"
  retries_left=10
  while [[ ${retries_left} -gt 0 ]]; do
    echo 'Configuring the runner.'

    if [ -f /runner/.runner ]; then
      echo 'Runner already configured.'
      break
    fi
    cd /runner
    ./config.sh \
      --unattended \
      --replace \
      --disableupdate \
      --name "${RUNNER_NAME}" \
      --url "https://github.com/$ATTACH" \
      --token "$RUNNER_TOKEN" \
      --no-default-labels \
      --labels "${RUNNER_LABELS}"
    cd - >/dev/null
    if [ -f /runner/.runner ]; then
      echo 'Runner successfully configured.'
      break
    fi

    echo 'Configuration failed. Retrying'
    retries_left=$((retries_left - 1))
    sleep 1
  done

  if [ ! -f /runner/.runner ]; then
    # we couldn't configure and register the runner; no point continuing
    echo 'Configuration failed!'
    exit 2
  fi

  jq -c . </runner/.runner
}

stop_docker() {
  if [ -f /var/run/docker.pid ]; then
    docker_pid="$(cat /var/run/docker.pid)"
    if ps -p "${docker_pid}" >/dev/null 2>&1; then
      echo "Stopping docker ${docker_pid}"
      sudo pkill dockerd || true
      i=0
      max=10
      while [ -n "$(pgrep dockerd)" ] && [ "$i" -le "$max" ]; do
        echo "Waiting for docker to stop ($i/$max)"
        i=$((i + 1))
        sleep 1
      done
    fi
    echo "Docker stopped"
  else
    echo "Docker should not be stopped here."
  fi
}

execute_runner() {
  # Unset entrypoint environment variables so they don't leak into the runner environment
  # without loosing the runner token
  # Doing it in background because I need to handle signals
  dumb-init bash <<'SCRIPT' &
set -e
unset RUNNER_NAME RUNNER_REPO RUNNER_TOKEN STARTUP_DELAY_IN_SECONDS DISABLE_WAIT_FOR_DOCKER
cd /runner
./run.sh
SCRIPT
  run_pid=$!

  echo "run.sh running with pid ${run_pid}"
  #looping wait because signals cause an exit of wait.
  while wait "${run_pid}"; do
    :
  done
}

function wait_for_process() {
  local max_time_wait=30
  local process_name="$1"
  local waited_sec=0
  while ! pgrep "$process_name" >/dev/null && ((waited_sec < max_time_wait)); do
    echo "Process $process_name is not running yet. Retrying in 1 seconds"
    echo "Waited $waited_sec seconds of $max_time_wait seconds"
    sleep 1
    ((waited_sec = waited_sec + 1))
    if ((waited_sec >= max_time_wait)); then
      return 1
    fi
  done
  return 0
}

main() {
  check_env
  setup_cache_ca
  start_docker
  configure_runner
  execute_runner
  echo "Runner terminated"
  stop_docker
  echo "Runner stopped"
}

main
