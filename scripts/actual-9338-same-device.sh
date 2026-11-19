#!/usr/bin/env bash
# actualbudget/actual#9338: does the proposed "/app subfolder" check hold when a
# data volume is on the same device as /app, and with nested mounts?
#
#   bash actual-9338-same-device.sh > out.log 2>&1
#
# Two engines:
#   overlay  the local Docker engine (containerd overlayfs snapshotter)
#   vfs      a second engine in the container f9338dind, started with
#            --storage-driver=vfs, where the image and the volumes are plain
#            folders on one filesystem:
#              docker run -d --privileged --name f9338dind -e DOCKER_TLS_CERTDIR= \
#                -v f9338dindlib:/var/lib/docker docker:dind --storage-driver=vfs
#            with the images below copied in (docker save | docker load)
#
# Images (override with environment variables):
#   PR   the PR head, built from sync-server.Dockerfile
#   V1   PR + the entrypoint check as first proposed (owner and device)
#   V2   PR + the revised check (owner and mount point)
#   OLD  the last released image, which runs as root; used to make older data
#   FLATV2  the released layout (code directly in /app) + the revised check
#
# On a machine whose own engine is the one to test (a CI runner switched to
# vfs), name the local engine and leave the second engine out:
#   LOCAL=host ENGINES=host SAME_FS_BIND=/var/lib/docker/f9338sbind bash ...
# LOCAL is only the label printed for the local engine. SAME_FS_BIND is a
# folder on the filesystem that holds the image, for case D; it is made and
# removed with sudo and its name must end in /f9338sbind.
#
# Uses the container name f9338s and volumes named f9338s*, in each engine, and
# removes them at the end.
set -u
export MSYS_NO_PATHCONV=1

PR=${PR:-actual-pr9338:e9e7854}
V1=${V1:-f9338-patched:local}
V2=${V2:-f9338-patched3:local}
OLD=${OLD:-actualbudget/actual-server:26.10.0}
LOCAL=${LOCAL:-overlay}
ENGINE=$LOCAL
SAME_FS_BIND=${SAME_FS_BIND:-}
case $SAME_FS_BIND in ''|*/f9338sbind) ;; *) echo "SAME_FS_BIND must end in /f9338sbind" >&2; exit 2 ;; esac

dk() {
  if [ "$ENGINE" = vfs ]; then docker exec -i f9338dind docker "$@"; else docker "$@"; fi
}

# engine_sh <command>: runs a command where the engine keeps its files.
engine_sh() {
  if [ "$ENGINE" = vfs ]; then docker exec f9338dind sh -c "$1"; else sudo sh -c "$1"; fi
}

say() { printf '\n=== [%s] %s\n' "$ENGINE" "$*"; }
note() { printf -- '--- %s\n' "$*"; }

procs() {
  dk exec f9338s sh -c 'for p in /proc/[0-9]*; do n=$(sed -n "s/^Name:\t//p" $p/status 2>/dev/null); u=$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" $p/status 2>/dev/null); echo "$n uid=$u"; done' 2>/dev/null |
    grep -E '^(MainThread|node) ' | sort -u | sed 's/^/  process: /'
}

settle() {
  for _ in $(seq 1 40); do
    [ "$(dk inspect f9338s --format '{{.State.Status}}')" = running ] || break
    dk logs f9338s 2>&1 | grep -q 'Listening on' && break
    sleep 1
  done
  sleep 2
}

report() {
  dk inspect f9338s --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  dk logs f9338s 2>&1 | grep -E '^(Warning|Error|Set it|Give|Allow)|Listening on' | head -6 | sed 's/^/  log: /'
  procs
}

# run <docker run arguments...>: starts the container f9338s and reports on it.
run() {
  dk container rm -f f9338s >/dev/null 2>&1
  printf '$ docker run %s\n' "$*"
  if ! dk run -d --name f9338s "$@" >/dev/null; then
    echo '  docker run failed'
    return
  fi
  settle
  report
}

restart() {
  echo '$ docker restart f9338s'
  dk restart f9338s >/dev/null
  sleep 2
  settle
  report
}

running() { [ "$(dk inspect f9338s --format '{{.State.Status}}' 2>/dev/null)" = running ]; }

# owners <paths...>: owner, device number and whether it is a mount point.
owners() {
  running || return 0
  dk exec f9338s sh -c 'for f in "$@"; do m=no; mountpoint -q "$f" 2>/dev/null && m=yes; stat -c "  owner: %u:%g dev=%d mount=$m %n" "$f" 2>&1; done' sh "$@"
}

http() {
  running || return 0
  dk exec f9338s node -e '
    const [, method, path, body] = process.argv;
    fetch("http://localhost:5006" + path, { method, headers: { "content-type": "application/json" }, body })
      .then(async r => console.log("  http:", method, path, "->", r.status, (await r.text()).slice(0, 60).replace(/"token":"[^"]*"/, "\"token\":\"...\"")))
      .catch(e => console.log("  http:", method, path, "-> failed", e.cause?.code || e.message));
  ' "$@" 2>&1
}

# Sets a password if there is none yet, then signs in with it.
sign_in_check() {
  http POST /account/bootstrap '{"password":"test-password-9338"}'
  http POST /account/login '{"password":"test-password-9338"}'
}

# old_data <docker run arguments...>: starts the released image, which runs as
# root, with these arguments so it creates its data, then removes the container.
old_data() {
  dk container rm -f f9338s >/dev/null 2>&1
  dk run -d --name f9338s "$@" "$OLD" >/dev/null
  settle
  printf -- '--- older data made by %s as uid %s\n' "$OLD" "$(dk exec f9338s id -u 2>&1)"
  dk container rm -f f9338s >/dev/null 2>&1
}

fresh_volumes() {
  dk container rm -f f9338s >/dev/null 2>&1
  dk volume rm f9338s1 f9338s2 >/dev/null 2>&1
  dk volume create f9338s1 >/dev/null
  dk volume create f9338s2 >/dev/null
}

suite() {
  ENGINE=$1
  printf '\n##########################################################\n'
  printf '# engine: %s\n' "$ENGINE"
  printf '##########################################################\n'
  echo "docker: $(dk version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'), storage driver $(dk info --format '{{.Driver}}')"
  for image in "$PR" "$V1" "$V2" "$OLD"; do
    echo "image: $image $(dk image inspect "$image" --format '{{.Id}}')"
  done
  for image in "$PR" "$V1" "$V2"; do
    echo "entrypoint in $image: $(dk run --rm --entrypoint sha256sum "$image" /usr/local/bin/docker-entrypoint.sh | cut -d' ' -f1)"
  done

  say 'A. Default settings, older root-owned data in a volume at /data (control)'
  for image in "$V1" "$V2"; do
    fresh_volumes
    old_data -v f9338s1:/data
    run -v f9338s1:/data "$image"
    owners /app /data /data/server-files
  done

  # /data is kept in a second volume in B and K: the migration state is in the
  # data folder, and the server can't start on older files without it.
  say 'B. Volume at /app/server-files with older root-owned data'
  for image in "$PR" "$V1" "$V2"; do
    fresh_volumes
    old_data -e ACTUAL_SERVER_FILES=/app/server-files -v f9338s1:/app/server-files -v f9338s2:/data
    run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338s1:/app/server-files -v f9338s2:/data "$image"
    owners /app /app/server-files /app/server-files/account.sqlite /data
    sign_in_check
  done

  say 'C. New, empty volume at /app/server-files'
  for image in "$V1" "$V2"; do
    fresh_volumes
    run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338s1:/app/server-files "$image"
    owners /app /app/server-files
  done

  bind=$SAME_FS_BIND
  [ "$ENGINE" = vfs ] && bind=/var/lib/docker/f9338sbind
  if [ -n "$bind" ]; then
    say 'D. Bind mount at /app/server-files from the filesystem that holds the image'
    for image in "$V1" "$V2"; do
      dk container rm -f f9338s >/dev/null 2>&1
      engine_sh "rm -rf $bind && mkdir $bind"
      run -e ACTUAL_SERVER_FILES=/app/server-files -v "$bind:/app/server-files" "$image"
      owners /app /app/server-files
    done
    dk container rm -f f9338s >/dev/null 2>&1
    engine_sh "rm -rf $bind"
  fi

  say 'E. ACTUAL_SERVER_FILES=/app/build (server code)'
  for image in "$V1" "$V2"; do
    run -e ACTUAL_SERVER_FILES=/app/build "$image"
    owners /app /app/build /app/build/app.js
  done

  say 'F. ACTUAL_SERVER_FILES=/app/node_modules'
  for image in "$V1" "$V2"; do
    run -e ACTUAL_SERVER_FILES=/app/node_modules "$image"
    owners /app/node_modules
  done

  say 'G. New folder /app/server-files, no volume, then a restart'
  for image in "$V1" "$V2"; do
    run -e ACTUAL_SERVER_FILES=/app/server-files "$image"
    owners /app /app/server-files
    restart
  done

  say 'H. Nested mounts: volume at /app/data, second volume at /app/data/user-files, older root-owned data'
  for image in "$PR" "$V1" "$V2"; do
    fresh_volumes
    old_data -e ACTUAL_DATA_DIR=/app/data -v f9338s1:/app/data -v f9338s2:/app/data/user-files
    run -e ACTUAL_DATA_DIR=/app/data -v f9338s1:/app/data -v f9338s2:/app/data/user-files "$image"
    owners /app /app/data /app/data/server-files /app/data/server-files/account.sqlite /app/data/user-files
  done

  say 'I. Nested mounts: /app/data is not a mount, new volumes at /app/data/server-files and /app/data/user-files'
  for image in "$PR" "$V1" "$V2"; do
    fresh_volumes
    run -e ACTUAL_DATA_DIR=/app/data -v f9338s1:/app/data/server-files -v f9338s2:/app/data/user-files "$image"
    owners /app /app/data /app/data/server-files /app/data/user-files
  done

  say 'J. Nested mounts: ACTUAL_SERVER_FILES=/app/build with a volume at /app/build/data'
  for image in "$PR" "$V1" "$V2"; do
    fresh_volumes
    run -e ACTUAL_SERVER_FILES=/app/build -v f9338s1:/app/build/data "$image"
    owners /app /app/build /app/build/app.js /app/build/data
  done

  say 'K. Volume at a path with a space, "/app/my data", older root-owned data'
  for image in "$V1" "$V2"; do
    fresh_volumes
    old_data -e 'ACTUAL_SERVER_FILES=/app/my data' -v 'f9338s1:/app/my data' -v f9338s2:/data
    run -e 'ACTUAL_SERVER_FILES=/app/my data' -v 'f9338s1:/app/my data' -v f9338s2:/data "$image"
    owners /app '/app/my data' '/app/my data/account.sqlite'
    sign_in_check
  done

  dk container rm -f f9338s >/dev/null 2>&1
  dk volume rm f9338s1 f9338s2 >/dev/null 2>&1
}

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for engine in ${ENGINES:-$LOCAL vfs}; do
  suite "$engine"
done

# The released layout (code directly in /app), local engine only.
ENGINE=$LOCAL
FLATV2=${FLATV2:-f9338-flat-patched3:local}
echo
echo "image: $FLATV2 $(dk image inspect "$FLATV2" --format '{{.Id}}')"
say 'L1. Released layout + revised check, ACTUAL_SERVER_FILES=/app/chunks'
run -e ACTUAL_SERVER_FILES=/app/chunks "$FLATV2"
owners /app /app/app.js /app/chunks
say 'L2. Released layout + revised check, new volume at /app/server-files'
fresh_volumes
run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338s1:/app/server-files "$FLATV2"
owners /app /app/server-files
dk container rm -f f9338s >/dev/null 2>&1
dk volume rm f9338s1 f9338s2 >/dev/null 2>&1
echo
echo "left over: containers [$(docker ps -aq --filter name=f9338s | wc -l)] volumes [$(docker volume ls -q --filter name=f9338s | wc -l)] (local engine)"
echo "done: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
