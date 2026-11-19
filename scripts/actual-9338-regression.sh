#!/bin/sh
# Pass/fail checks for the sync-server Docker entrypoint (actualbudget/actual#9338):
# a config.json that root can not read, and startup as a non-root user.
#
#   sh actual-9338-regression.sh <image>
#
# Needs only Docker. Exits 1 if a check fails.
#
# Root squash is stood in for locally: /data is 0700 and owned by the run user,
# and the container runs without DAC_OVERRIDE and DAC_READ_SEARCH, so root gets
# EACCES on /data/config.json, as it does on a root-squash NFS export.
#
# Uses the container f9338r and the volumes f9338rdata and f9338rsrv, and
# removes them at the end.
set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: leave container paths alone

image=${1:?usage: actual-9338-regression.sh <image>}
fails=0
checks=0
LOCKED='--cap-drop DAC_OVERRIDE --cap-drop DAC_READ_SEARCH'
CONFIG='{"serverFiles":"/srv/actual/server-files"}'
# Writes that config.json and closes /data to everyone but its owner. Run by the
# shell of the helper container, which is where $CONFIG is expanded.
# shellcheck disable=SC2016
WRITE_CONFIG='printf "%s" "$CONFIG" > /data/config.json; chmod 700 /data; chmod 600 /data/config.json'

case_() { printf '\n%s\n' "$*"; }

check() { # <what> <got> <want>
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok    %s: %s\n' "$1" "$2"
  else
    printf '  FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

clean() {
  docker container rm -f f9338r >/dev/null 2>&1
  docker volume rm -f f9338rdata f9338rsrv >/dev/null 2>&1
}

# prepare <shell commands>: runs them as root in a helper container that has
# both volumes mounted, before the server is started.
prepare() {
  docker run --rm --entrypoint sh -e CONFIG="$CONFIG" \
    -v f9338rdata:/data -v f9338rsrv:/srv/actual "$image" -c "$1"
}

# start <docker run arguments...>: starts the server and waits until it
# listens or stops.
start() {
  docker container rm -f f9338r >/dev/null 2>&1
  docker run -d --name f9338r -v f9338rdata:/data -v f9338rsrv:/srv/actual "$@" "$image" >/dev/null
  i=0
  while [ "$i" -lt 40 ]; do
    [ "$(state)" = running ] || break
    docker logs f9338r 2>&1 | grep -q 'Listening on' && break
    sleep 1
    i=$((i + 1))
  done
  sleep 2
  # A server that stopped: show why.
  if [ "$(state)" != running ]; then
    docker logs f9338r 2>&1 | grep -m1 'Error' | cut -c1-110 | sed 's/^/  log: /'
  fi
}

state() { docker inspect f9338r --format '{{.State.Status}}' 2>/dev/null; }
exit_code() { docker inspect f9338r --format '{{.State.ExitCode}}' 2>/dev/null; }
warnings() { docker logs f9338r 2>&1 | grep -c '^Warning' ; }
first_error() { docker logs f9338r 2>&1 | grep -m1 '^Error' | cut -c1-60; }

# uid the server process runs as, or "none".
server_uid() {
  if [ "$(state)" != running ]; then echo none; return; fi
  docker exec f9338r sh -c 'for p in /proc/[0-9]*; do
      if [ "$(sed -n "s/^Name:\t//p" "$p/status" 2>/dev/null)" = MainThread ]; then
        sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" "$p/status"
      fi
    done' 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'
}

owner() { # <path>
  if [ "$(state)" != running ]; then echo none; return; fi
  docker exec f9338r stat -c '%u:%g' "$1" 2>/dev/null || echo missing
}

# Sets a password, signs in with it, and prints the HTTP status of the sign-in.
sign_in() {
  if [ "$(state)" != running ]; then echo none; return; fi
  docker exec f9338r node -e '
    const post = path => fetch("http://localhost:5006" + path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ password: "regression-test-9338" }),
    });
    post("/account/bootstrap").then(() => post("/account/login")).then(async r => {
      const { data } = await r.json();
      console.log(r.status + (data?.token ? " with a token" : " without a token"));
    }).catch(e => console.log("failed " + (e.cause?.code || e.message)));
  ' 2>&1
}

echo "image: $image $(docker image inspect "$image" --format '{{.Id}}')"
echo "entrypoint: $(docker run --rm --entrypoint sha256sum "$image" /usr/local/bin/docker-entrypoint.sh | cut -c1-64)"

case_ 'C1. Started as root, default settings, new volume (control)'
clean
start
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'warnings' "$(warnings)" 0
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'S1. Root can not read config.json; it names a folder on a second, root-owned volume'
clean
prepare "$WRITE_CONFIG; chown -R 1001:1001 /data"
# shellcheck disable=SC2086
start $LOCKED
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'warnings' "$(warnings)" 0
check 'owner of /srv/actual/server-files' "$(owner /srv/actual/server-files)" 1001:1001
check 'sign-in' "$(sign_in)" '200 with a token'
check 'owner of account.sqlite' "$(owner /srv/actual/server-files/account.sqlite)" 1001:1001

case_ 'S2. As S1, with the folder already there, empty and root-owned'
clean
prepare "$WRITE_CONFIG; chown -R 1001:1001 /data; mkdir /srv/actual/server-files"
# shellcheck disable=SC2086
start $LOCKED
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'owner of /srv/actual/server-files' "$(owner /srv/actual/server-files)" 1001:1001
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'S3. As S1, with PUID=1000 PGID=1000'
clean
prepare "$WRITE_CONFIG; chown -R 1000:1000 /data"
# shellcheck disable=SC2086
start $LOCKED -e PUID=1000 -e PGID=1000
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1000
check 'owner of /srv/actual/server-files' "$(owner /srv/actual/server-files)" 1000:1000
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'S4. As S1, with ACTUAL_SERVER_FILES set as well: the environment wins'
clean
prepare "$WRITE_CONFIG; chown -R 1001:1001 /data"
# shellcheck disable=SC2086
start $LOCKED -e ACTUAL_SERVER_FILES=/srv/actual/from-env
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'owner of /srv/actual/from-env' "$(owner /srv/actual/from-env)" 1001:1001
check 'owner of /srv/actual/server-files' "$(owner /srv/actual/server-files)" missing
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'S5. As S1, but root can read config.json (control)'
clean
prepare "$WRITE_CONFIG; chown -R 1001:1001 /data"
start
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'owner of /srv/actual/server-files' "$(owner /srv/actual/server-files)" 1001:1001

case_ 'U1. --user 1001:1001, default settings, new volume'
clean
start --user 1001:1001
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'warnings' "$(warnings)" 0
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'U2. --user 1001:1001, config.json names a folder in the data volume'
clean
prepare 'printf "%s" "{\"serverFiles\":\"/data/custom\"}" > /data/config.json; chown -R 1001:1001 /data; chmod 700 /data; chmod 600 /data/config.json'
start --user 1001:1001
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1001
check 'sign-in' "$(sign_in)" '200 with a token'
check 'owner of /data/custom/account.sqlite' "$(owner /data/custom/account.sqlite)" 1001:1001

case_ 'U3. --user 1000:1000 on data that uid 1000 owns'
clean
# Docker copies the image's /data, owner included, into a volume for as long as
# the volume is empty, so the folder gets something in it first.
prepare 'mkdir /data/server-files; chown -R 1000:1000 /data'
start --user 1000:1000
check 'state' "$(state)" running
check 'server uid' "$(server_uid)" 1000
check 'sign-in' "$(sign_in)" '200 with a token'

case_ 'U4. --user 1000:1000 on data that uid 1001 owns: stops with the error'
clean
start --user 1000:1000
check 'state' "$(state)" exited
check 'exit code' "$(exit_code)" 1
check 'first error' "$(first_error)" "Error: uid 1000 can't write to /data or something in it."

clean
left=$(docker ps -a --filter name=f9338r --format '{{.Names}}'; docker volume ls --filter name=f9338r --format '{{.Name}}')
printf '\n%s checks, %s failed%s\n' "$checks" "$fails" "${left:+, left over: $left}"
[ "$fails" -eq 0 ]
