setup() {
  set -eu -o pipefail
  export DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export TESTDIR=~/tmp/test-drupal-ai-observability
  mkdir -p $TESTDIR
  export PROJNAME=test-drupal-ai-observability
  export DDEV_NONINTERACTIVE=true
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  ddev config --project-name=${PROJNAME} --project-type=php
  ddev start -y >/dev/null
}

health_checks() {
  # Grafana answers and is healthy.
  curl -fs "https://${PROJNAME}.ddev.site:3000/api/health" | grep -q '"database"'
  # Tempo is ready and its OTLP HTTP receiver is open (the reason for the 2.6.1 pin).
  ddev exec "curl -s -o /dev/null -w '%{http_code}' http://grafana-tempo:3200/ready" | grep -q '200'
  ddev exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://grafana-tempo:4318/v1/traces -H 'Content-Type: application/json' -d '{}'" | grep -q '200'
  # Alloy OTLP receiver reachable from the web container.
  ddev exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://grafana-alloy:4318/v1/traces -H 'Content-Type: application/json' -d '{}'" | grep -q '200'
  # The AI dashboards are provisioned.
  curl -fs -u admin:admin "https://${PROJNAME}.ddev.site:3000/api/dashboards/uid/ai-agent-sessions" | grep -q '"uid":"ai-agent-sessions"'
  curl -fs -u admin:admin "https://${PROJNAME}.ddev.site:3000/api/dashboards/uid/ai-requests-overview" | grep -q '"uid":"ai-requests-overview"'
  curl -fs -u admin:admin "https://${PROJNAME}.ddev.site:3000/api/dashboards/uid/ai-tokens-cost" | grep -q '"uid":"ai-tokens-cost"'
  curl -fs -u admin:admin "https://${PROJNAME}.ddev.site:3000/api/dashboards/uid/ai-latency-explorer" | grep -q '"uid":"ai-latency-explorer"'
  # The model-price sync command works end-to-end (models.dev -> Alloy -> Mimir).
  ddev sync-model-prices | grep -q 'Synced'
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

@test "install from release" {
  set -eu -o pipefail
  cd ${TESTDIR} || ( printf "unable to cd to ${TESTDIR}\n" && exit 1 )
  echo "# ddev add-on get ivanboring/ddev-drupal-ai-observability with project ${PROJNAME} in ${TESTDIR} ($(pwd))" >&3
  ddev add-on get ivanboring/ddev-drupal-ai-observability
  ddev restart >/dev/null
  health_checks
}
