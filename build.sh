#!/usr/bin/env bash
set -e

dc="docker-compose --no-ansi"
dcr="$dc run --rm"

# Thanks to https://unix.stackexchange.com/a/145654/108960
log_file="sentry_install_log-`date +'%Y-%m-%d_%H-%M-%S'`.txt"
exec &> >(tee -a "$log_file")

MIN_DOCKER_VERSION='17.05.0'
MIN_COMPOSE_VERSION='1.23.0'
MIN_RAM=2400 # MB

SENTRY_CONFIG_PY='sentry/sentry.conf.py'
SENTRY_CONFIG_YML='sentry/config.yml'
SENTRY_EXTRA_REQUIREMENTS='sentry/requirements.txt'

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  echo "Cleaning up..."
  $dc stop &> /dev/null
  DID_CLEAN_UP=1
}
trap cleanup ERR INT TERM

echo "Checking minimum requirements..."

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
COMPOSE_VERSION=$($dc --version | sed 's/docker-compose version \(.\{1,\}\),.*/\1/')
RAM_AVAILABLE_IN_DOCKER=$(docker run --rm busybox free -m 2>/dev/null | awk '/Mem/ {print $2}');

# Compare dot-separated strings - function below is inspired by https://stackoverflow.com/a/37939589/808368
function ver () { echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'; }

# Thanks to https://stackoverflow.com/a/25123013/90297 for the quick `sed` pattern
function ensure_file_from_example {
  if [ -f "$1" ]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1" | sed 's/\.[^.]*$/.example&/') "$1"
  fi
}

if [ $(ver $DOCKER_VERSION) -lt $(ver $MIN_DOCKER_VERSION) ]; then
    echo "FAIL: Expected minimum Docker version to be $MIN_DOCKER_VERSION but found $DOCKER_VERSION"
    exit 1
fi

if [ $(ver $COMPOSE_VERSION) -lt $(ver $MIN_COMPOSE_VERSION) ]; then
    echo "FAIL: Expected minimum docker-compose version to be $MIN_COMPOSE_VERSION but found $COMPOSE_VERSION"
    exit 1
fi

if [ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM" ]; then
    echo "FAIL: Expected minimum RAM available to Docker to be $MIN_RAM MB but found $RAM_AVAILABLE_IN_DOCKER MB"
    exit 1
fi

#SSE4.2 required by Clickhouse (https://clickhouse.yandex/docs/en/operations/requirements/) 
SUPPORTS_SSE42=$(docker run --rm busybox grep -c sse4_2 /proc/cpuinfo || :);
if (($SUPPORTS_SSE42 == 0)); then
    echo "FAIL: The CPU your machine is running on does not support the SSE 4.2 instruction set, which is required for one of the services Sentry uses (Clickhouse). See https://git.io/JvLDt for more info."
    exit 1
fi

# Clean up old stuff and ensure nothing is working while we install/update
# This is for older versions of on-premise:
$dc -p onpremise down --rmi local --remove-orphans
# This is for newer versions
$dc down --rmi local --remove-orphans

echo ""
ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example $SENTRY_EXTRA_REQUIREMENTS

if grep -xq "system.secret-key: '!!changeme!!'" $SENTRY_CONFIG_YML ; then
    echo ""
    echo "Generating secret key..."
    # This is to escape the secret key to be used in sed below
    # Note the need to set LC_ALL=C due to BSD tr and sed always trying to decode
    # whatever is passed to them. Kudos to https://stackoverflow.com/a/23584470/90297
    SECRET_KEY=$(export LC_ALL=C; head /dev/urandom | tr -dc "a-z0-9@#%^&*(-_=+)" | head -c 50 | sed -e 's/[\/&]/\\&/g')
    sed -i -e 's/^system.secret-key:.*$/system.secret-key: '"'$SECRET_KEY'"'/' $SENTRY_CONFIG_YML
    echo "Secret key written to $SENTRY_CONFIG_YML"
fi

echo ""
echo "Building and tagging Docker images..."
echo ""
# Build the sentry onpremise image first as it is needed for the cron image
$dc pull --ignore-pull-failures
$dc build --force-rm web
$dc build --force-rm --parallel
echo ""
echo "Docker images built."

cleanup

echo ""
echo "----------------"
echo "You're all done! Run the following command to get Sentry running:"
echo ""
echo "  docker-compose up -d"
echo ""
