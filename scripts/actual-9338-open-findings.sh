#!/usr/bin/env bash
# Runs the three open review findings on actualbudget/actual#9338 against the
# PR image, and the same cases against an image with a patched entrypoint.
#
#   bash actual-9338-open-findings.sh > out.log 2>&1
#
# Images (override with environment variables):
#   PR       the PR head, built from sync-server.Dockerfile (code in /app/build)
#   PATCHED  PR + the patched docker-entrypoint.sh
#   FLAT     PR with the build output directly in /app, as
#            packages/sync-server/docker/ubuntu.Dockerfile and the released
#            images lay it out
#   FLATP    FLAT + the patched docker-entrypoint.sh
#   OLD      the last released image
#   NFS      a local NFS server with a root-squash export (see
#            actual-9338-images/nfs-rootsquash)
#
# Everything uses the container names f9338 / f9338nfs and volumes named
# f9338*, and removes them at the end. Nothing is mounted from the host.
set -u
export MSYS_NO_PATHCONV=1

PR=${PR:-actual-pr9338:e9e7854}
PATCHED=${PATCHED:-f9338-patched:local}
FLAT=${FLAT:-f9338-flat:local}
FLATP=${FLATP:-f9338-flat-patched:local}
OLD=${OLD:-actualbudget/actual-server:26.10.0}
NFS=${NFS:-f9338-nfs-rootsquash:local}

say() { printf '\n=== %s\n' "$*"; }
note() { printf -- '--- %s\n' "$*"; }

procs() {
  docker exec f9338 sh -c 'for p in /proc/[0-9]*; do n=$(sed -n "s/^Name:\t//p" $p/status 2>/dev/null); u=$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" $p/status 2>/dev/null); echo "$n uid=$u"; done' 2>/dev/null |
    grep -E '^(MainThread|node|tini) ' | sed 's/^/  process: /'
}

report() {
  docker inspect f9338 --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  docker logs f9338 2>&1 | grep -v '^    at \|^$' | head -12 | sed 's/^/  log: /'
  procs
}

settle() {
  for _ in $(seq 1 30); do
    [ "$(docker inspect f9338 --format '{{.State.Status}}')" = running ] || break
    docker logs f9338 2>&1 | grep -q 'Listening on' && break
    sleep 1
  done
  sleep 3
}

# run <docker run arguments...>: starts the container f9338 and reports on it.
run() {
  docker container rm -f f9338 >/dev/null 2>&1
  printf '$ docker run %s\n' "$*"
  if ! docker run -d --name f9338 "$@" >/dev/null; then
    echo '  docker run failed'
    return
  fi
  settle
  report
}

restart() {
  echo '$ docker restart f9338'
  docker restart f9338 >/dev/null
  sleep 2
  settle
  docker inspect f9338 --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  docker logs --tail 4 f9338 2>&1 | sed 's/^/  log: /'
  procs
}

running() { [ "$(docker inspect f9338 --format '{{.State.Status}}' 2>/dev/null)" = running ]; }

owners() { running && docker exec f9338 stat -c '  owner: %u:%g %a %n' "$@" 2>&1; }

http() {
  running || return 0
  docker exec f9338 node -e '
    const [, method, path, body] = process.argv;
    fetch("http://localhost:5006" + path, { method, headers: { "content-type": "application/json" }, body })
      .then(async r => console.log("  http:", method, path, "->", r.status, (await r.text()).slice(0, 110)))
      .catch(e => console.log("  http:", method, path, "-> failed", e.cause?.code || e.message));
  ' "$@" 2>&1
}

# Sets a password if there is none yet, then signs in with it.
sign_in_check() {
  http GET /account/needs-bootstrap
  http POST /account/bootstrap '{"password":"test-password-9338"}'
  http POST /account/login '{"password":"test-password-9338"}'
}

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "docker: $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}')"
for image in "$PR" "$PATCHED" "$FLAT" "$FLATP" "$OLD" "$NFS"; do
  echo "image: $image $(docker image inspect "$image" --format '{{.Id}}')"
done
echo "entrypoint in PR:      $(docker run --rm --entrypoint sha256sum "$PR" /usr/local/bin/docker-entrypoint.sh)"
echo "entrypoint in PATCHED: $(docker run --rm --entrypoint sha256sum "$PATCHED" /usr/local/bin/docker-entrypoint.sh)"

###########################################################################
say 'FINDING 1: a folder of server code inside /app is handed over'
###########################################################################

say '1a. PR image, default settings (control)'
run "$PR"
owners /app /app/build /app/build/app.js /app/node_modules

say '1b. PR image, ACTUAL_SERVER_FILES=/app/build'
run -e ACTUAL_SERVER_FILES=/app/build "$PR"
owners /app /app/build /app/build/app.js /app/build/chunks /app/node_modules
note 'as uid 1001: append a line to app.js, show it, put the file back'
docker exec -u 1001:1001 f9338 sh -c 'cp /app/build/app.js /tmp/app.js.orig && echo "// written by uid $(id -u)" >> /app/build/app.js && tail -c 24 /app/build/app.js && cp /tmp/app.js.orig /app/build/app.js' 2>&1 | sed 's/^/  /'

say '1c. Released layout (code directly in /app), ACTUAL_SERVER_FILES=/app/chunks'
run -e ACTUAL_SERVER_FILES=/app/chunks "$FLAT"
owners /app /app/app.js /app/chunks
docker exec f9338 sh -c 'ls -n /app/chunks | head -4' | sed 's/^/  /'

say '1d. PATCHED, ACTUAL_SERVER_FILES=/app/build'
run -e ACTUAL_SERVER_FILES=/app/build "$PATCHED"
owners /app/build /app/build/app.js

say '1e. PATCHED, ACTUAL_SERVER_FILES=/app/node_modules'
run -e ACTUAL_SERVER_FILES=/app/node_modules "$PATCHED"
owners /app/node_modules

say '1f. PATCHED, released layout, ACTUAL_SERVER_FILES=/app/chunks'
run -e ACTUAL_SERVER_FILES=/app/chunks "$FLATP"
owners /app/chunks

say '1g. PATCHED, ACTUAL_SERVER_FILES=/app (was already refused)'
run -e ACTUAL_SERVER_FILES=/app "$PATCHED"

say '1h. PATCHED, default settings'
run "$PATCHED"
sign_in_check

say '1i. PATCHED, ACTUAL_SERVER_FILES=/app/server-files (new folder, no volume), then a restart'
run -e ACTUAL_SERVER_FILES=/app/server-files "$PATCHED"
owners /app/server-files
sign_in_check
restart
owners /app/server-files

say '1j. PATCHED, ACTUAL_SERVER_FILES=/app/x/y (new nested folder), then a restart'
run -e ACTUAL_SERVER_FILES=/app/x/y "$PATCHED"
owners /app/x /app/x/y
restart

say '1k. PATCHED, a volume at /app/server-files holding root-owned data from the old image'
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338app f9338data >/dev/null 2>&1
run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338data:/data -v f9338app:/app/server-files "$OLD"
sign_in_check
owners /app/server-files /app/server-files/account.sqlite
run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338data:/data -v f9338app:/app/server-files "$PATCHED"
owners /app/server-files /app/server-files/account.sqlite
sign_in_check
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338app f9338data >/dev/null 2>&1

###########################################################################
say 'FINDING 2: a privileged port without NET_BIND_SERVICE'
###########################################################################

say '2a. PR image, port 443, threshold 1024, NET_BIND_SERVICE dropped'
run --sysctl net.ipv4.ip_unprivileged_port_start=1024 --cap-drop NET_BIND_SERVICE -e ACTUAL_PORT=443 "$PR"

say '2b. PR image, port 443, threshold 1024, capability kept (control)'
run --sysctl net.ipv4.ip_unprivileged_port_start=1024 -e ACTUAL_PORT=443 "$PR"

say '2c. Old image, as 2a'
run --sysctl net.ipv4.ip_unprivileged_port_start=1024 --cap-drop NET_BIND_SERVICE -e ACTUAL_PORT=443 "$OLD"

say '2d. Old image, as 2b (control)'
run --sysctl net.ipv4.ip_unprivileged_port_start=1024 -e ACTUAL_PORT=443 "$OLD"

say '2e. PR image, port 443, NET_BIND_SERVICE dropped, threshold left at the Docker default'
run --cap-drop NET_BIND_SERVICE -e ACTUAL_PORT=443 "$PR"
docker exec f9338 cat /proc/sys/net/ipv4/ip_unprivileged_port_start | sed 's/^/  ip_unprivileged_port_start: /'

say '2f. PR image, new named volume, --cap-drop ALL'
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338data >/dev/null 2>&1
run --cap-drop ALL -v f9338data:/data "$PR"
docker run --rm --entrypoint stat -v f9338data:/data "$PR" -c '  owner: %u:%g %a %n' /data

say '2g. Old image, new named volume, --cap-drop ALL'
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338data >/dev/null 2>&1
run --cap-drop ALL -v f9338data:/data "$OLD"
docker run --rm --entrypoint stat -v f9338data:/data "$PR" -c '  owner: %u:%g %a %n' /data

say '2h. PR image, new named volume, --cap-drop ALL --user 1001:1001'
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338data >/dev/null 2>&1
run --cap-drop ALL --user 1001:1001 -v f9338data:/data "$PR"
sign_in_check

say '2i. PR image, --cap-drop ALL, on a volume holding root-owned data from the old image'
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338data >/dev/null 2>&1
run -v f9338data:/data "$OLD"
sign_in_check
owners /data /data/server-files /data/server-files/account.sqlite
run --cap-drop ALL -v f9338data:/data "$PR"
sign_in_check
docker container rm -f f9338 >/dev/null 2>&1
docker volume rm -f f9338data >/dev/null 2>&1

###########################################################################
say 'FINDING 3: config.json that the run user can read and root cannot'
###########################################################################

# config.json names a serverFiles folder on a second volume.
CONFIG='{"serverFiles":"/srv/actual/server-files"}'

# A local stand-in: /data is 0700 and owned by the run user, and the container
# runs without DAC_OVERRIDE and DAC_READ_SEARCH, so root can not get in.
local_setup() { # <uid>
  docker container rm -f f9338 >/dev/null 2>&1
  docker volume rm -f f9338data f9338srv >/dev/null 2>&1
  docker run --rm --entrypoint sh -e CONFIG="$CONFIG" -e OWNER="$1" -v f9338data:/data -v f9338srv:/srv/actual "$PR" -c \
    'printf "%s" "$CONFIG" > /data/config.json; chown -R "$OWNER:$OWNER" /data; chmod 700 /data; chmod 600 /data/config.json; stat -c "  owner: %u:%g %a %n" /data /data/config.json /srv/actual'
}
LOCKED='--cap-drop DAC_OVERRIDE --cap-drop DAC_READ_SEARCH'

say '3a. Local stand-in, root not locked out (control), PR image'
local_setup 1001
run -v f9338data:/data -v f9338srv:/srv/actual "$PR"
owners /srv/actual /srv/actual/server-files

say '3b. Local stand-in, root locked out, PR image'
local_setup 1001
# shellcheck disable=SC2086
run $LOCKED -v f9338data:/data -v f9338srv:/srv/actual "$PR"

say '3c. Local stand-in, root locked out, PATCHED'
local_setup 1001
# shellcheck disable=SC2086
run $LOCKED -v f9338data:/data -v f9338srv:/srv/actual "$PATCHED"
owners /srv/actual /srv/actual/server-files
sign_in_check

say '3d. Local stand-in, root locked out, PUID=1000 PGID=1000, PATCHED'
local_setup 1000
# shellcheck disable=SC2086
run $LOCKED -e PUID=1000 -e PGID=1000 -v f9338data:/data -v f9338srv:/srv/actual "$PATCHED"
owners /srv/actual /srv/actual/server-files
sign_in_check

say '3i. Local stand-in, root locked out and SETUID/SETGID dropped too, PATCHED'
local_setup 1001
# shellcheck disable=SC2086
run $LOCKED --cap-drop SETUID --cap-drop SETGID -v f9338data:/data -v f9338srv:/srv/actual "$PATCHED"

say '3j. As 3i, PR image'
local_setup 1001
# shellcheck disable=SC2086
run $LOCKED --cap-drop SETUID --cap-drop SETGID -v f9338data:/data -v f9338srv:/srv/actual "$PR"

# The real thing: /data is an NFSv4 mount of a root-squash export.
nfs_up() {
  docker container rm -f f9338 f9338nfs >/dev/null 2>&1
  docker volume rm -f f9338export f9338nfsvol f9338srv >/dev/null 2>&1
  docker run -d --name f9338nfs --privileged -v f9338export:/export "$NFS" >/dev/null
  sleep 8
  ip=$(docker inspect f9338nfs --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
  docker volume create --driver local --opt type=nfs --opt "o=addr=$ip,nfsvers=4.2,rw,soft,timeo=50,retrans=2,noac" --opt device=:/export f9338nfsvol >/dev/null
  docker exec -e CONFIG="$CONFIG" f9338nfs sh -c \
    'printf "%s" "$CONFIG" > /export/config.json; chown -R 1001:1001 /export; chmod 700 /export; chmod 600 /export/config.json; stat -c "  on the NFS server: %u:%g %a %n" /export /export/config.json'
  docker run --rm --entrypoint sh -v f9338nfsvol:/data:nocopy "$PR" -c \
    'mount | sed -n "s/^\(.* on \/data type nfs4\) (\(rw\),.*\(vers=[0-9.]*\).*/  mount: \1 \2 \3/p"
     printf "  root reads config.json: "; cat /data/config.json 2>&1; echo
     printf "  uid 1001 reads config.json: "; setpriv --reuid=1001 --regid=1001 --clear-groups cat /data/config.json; echo
     printf "  root creates a file in /data: "; touch /data/x 2>&1 || true; echo'
}

say '3e. NFS root squash, serverFiles on an empty root-owned volume, PR image'
nfs_up
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$PR"

say '3f. NFS root squash, serverFiles on an empty root-owned volume, PATCHED'
nfs_up
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$PATCHED"
owners /srv/actual /srv/actual/server-files
sign_in_check

say '3g. NFS root squash, serverFiles already there, empty and root-owned, PR image'
nfs_up
docker run --rm --entrypoint sh -v f9338srv:/srv/actual "$PR" -c 'mkdir /srv/actual/server-files; stat -c "  owner: %u:%g %a %n" /srv/actual/server-files'
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$PR"

say '3h. NFS root squash, serverFiles already there, empty and root-owned, PATCHED'
nfs_up
docker run --rm --entrypoint sh -v f9338srv:/srv/actual "$PR" -c 'mkdir /srv/actual/server-files; stat -c "  owner: %u:%g %a %n" /srv/actual/server-files'
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$PATCHED"
owners /srv/actual/server-files /srv/actual/server-files/account.sqlite
sign_in_check

say 'cleanup'
docker container rm -f f9338 f9338nfs >/dev/null 2>&1
docker volume rm -f f9338data f9338srv f9338app f9338export f9338nfsvol >/dev/null 2>&1
docker ps -a --filter name=f9338 --format '{{.Names}}' | sed 's/^/  left over container: /'
docker volume ls --filter name=f9338 --format '{{.Name}}' | sed 's/^/  left over volume: /'
echo 'done'
