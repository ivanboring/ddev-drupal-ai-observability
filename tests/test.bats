setup() {
  set -eu -o pipefail
  export DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export TESTDIR=~/tmp/test-drupal-ai-observability
  mkdir -p $TESTDIR
  export PROJNAME=test-drupal-ai-observability
  export DDEV_NONINTERACTIVE=true
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  # Generous container timeout: on cold CI runners the 5 stack images are
  # pulled during the first start/restart, which easily exceeds the 120s
  # default readiness window.
  ddev config --project-name=${PROJNAME} --project-type=php --default-container-timeout=300
  ddev start -y >/dev/null
}

# Retry a check for up to ~3 minutes. Stack components need time after
# `ddev restart` — Tempo answers 503 on /ready for its first ~20s while the
# ingester joins its ring, and Grafana provisions dashboards after its
# health endpoint already reports ok. CI runners are slower than dev machines.
retry() {
  local tries=36
  while ! "$@"; do
    tries=$((tries - 1))
    if [ "$tries" -le 0 ]; then
      echo "# timed out waiting for: $*" >&3
      return 1
    fi
    sleep 5
  done
  return 0
}

# All checks run inside the web container (internal DDEV network) so the test
# does not depend on host DNS, /etc/hosts, or the mkcert CA of the runner.
grafana_healthy() {
  ddev exec "curl -fs http://grafana:3000/api/health" | grep -q '"database"'
}

tempo_ready() {
  ddev exec "curl -s -o /dev/null -w '%{http_code}' http://grafana-tempo:3200/ready" | grep -q '200'
}

tempo_otlp_open() {
  # The OTLP HTTP receiver answering is the whole point of the tempo 2.6.1 pin.
  ddev exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://grafana-tempo:4318/v1/traces -H 'Content-Type: application/json' -d '{}'" | grep -q '200'
}

alloy_otlp_open() {
  ddev exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://grafana-alloy:4318/v1/traces -H 'Content-Type: application/json' -d '{}'" | grep -q '200'
}

dashboard_provisioned() {
  ddev exec "curl -fs -u admin:admin http://grafana:3000/api/dashboards/uid/${1}" | grep -q "\"uid\":\"${1}\""
}

price_sync_works() {
  # End-to-end: models.dev -> sync script -> Alloy OTLP.
  ddev sync-model-prices | grep -q 'Synced'
}

health_checks() {
  retry grafana_healthy
  retry tempo_ready
  retry tempo_otlp_open
  retry alloy_otlp_open
  for uid in ai-agent-sessions ai-requests-overview ai-tokens-cost ai-latency-explorer; do
    retry dashboard_provisioned "${uid}"
  done
  retry price_sync_works
}

teardown() {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  ddev delete -Oy ${PROJNAME}
  [ "${TESTDIR}" != "" ] && rm -rf ${TESTDIR}
}

@test "install from directory" {
  set -eu -o pipefail
  cd ${TESTDIR}
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev add-on get ${DIR}
  ddev restart >/dev/null
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  echo "# ddev add-on get ivanboring/ddev-drupal-ai-observability with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev add-on get ivanboring/ddev-drupal-ai-observability
  ddev restart >/dev/null
  health_checks
}
