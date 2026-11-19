#!/usr/bin/env bash
# actualbudget/actual#9338: the NFS root-squash cases 3e and 3f of
# actual-9338-open-findings.sh against one NFS export, with probes that show
# which call fails for root and for uid 1001.
#
#   bash actual-9338-nfs-probe.sh ganesha
#       the export of the container f9338nfs (image $NFS, a user-space NFS
#       server), as in actual-9338-open-findings.sh
#   bash actual-9338-nfs-probe.sh host <address> <folder>
#       an export of this machine's own NFS server. <folder> is exported with
#       root_squash before this runs; its files are set up here with sudo, and
#       its name must end in /f9338export.
#
# Images (override with environment variables):
#   PR   the PR head
#   V2   PR + the revised entrypoint
#   NFS  the user-space NFS server image (actual-9338-images/nfs-rootsquash)
#
# Uses the containers f9338 and f9338nfs and volumes named f9338*, and removes
# them at the end.
set -u

kind=${1:?usage: actual-9338-nfs-probe.sh ganesha | host <address> <folder>}
PR=${PR:-actual-pr9338:e9e7854}
V2=${V2:-f9338-patched3:local}
NFS=${NFS:-f9338-nfs-rootsquash:local}
CONFIG='{"serverFiles":"/srv/actual/server-files"}'

say() { printf '\n=== %s\n' "$*"; }

procs() {
  docker exec f9338 sh -c 'for p in /proc/[0-9]*; do n=$(sed -n "s/^Name:\t//p" $p/status 2>/dev/null); u=$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" $p/status 2>/dev/null); echo "$n uid=$u"; done' 2>/dev/null |
    grep -E '^(MainThread|node|tini) ' | sed 's/^/  process: /'
}

settle() {
  for _ in $(seq 1 30); do
    [ "$(docker inspect f9338 --format '{{.State.Status}}')" = running ] || break
    docker logs f9338 2>&1 | grep -q 'Listening on' && break
    sleep 1
  done
  sleep 3
}

running() { [ "$(docker inspect f9338 --format '{{.State.Status}}' 2>/dev/null)" = running ]; }

run() {
  docker container rm -f f9338 >/dev/null 2>&1
  printf '$ docker run %s\n' "$*"
  if ! docker run -d --name f9338 "$@" >/dev/null; then
    echo '  docker run failed'
    return
  fi
  settle
  docker inspect f9338 --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  docker logs f9338 2>&1 | grep -v '^    at \|^$' | head -12 | sed 's/^/  log: /'
  procs
}

sign_in_check() {
  running || return 0
  docker exec f9338 node -e '
    const post = (path, body) =>
      fetch("http://localhost:5006" + path, { method: "POST", headers: { "content-type": "application/json" }, body })
        .then(r => console.log("  http: POST", path, "->", r.status))
        .catch(e => console.log("  http: POST", path, "-> failed", e.cause?.code || e.message));
    post("/account/bootstrap", JSON.stringify({ password: "test-password-9338" }))
      .then(() => post("/account/login", JSON.stringify({ password: "test-password-9338" })));
  ' 2>&1
}

# The calls the entrypoint makes on the data folder and on config.json, one by
# one, with the error code of each.
PROBE='
  const fs = require("fs");
  const tryIt = (name, fn) => {
    try { fn(); console.log("    " + name + ": ok"); }
    catch (e) { console.log("    " + name + ": " + e.code + " (" + e.syscall + ")"); }
  };
  tryIt("lstat /data", () => fs.lstatSync("/data"));
  tryIt("realpath /data", () => fs.realpathSync("/data"));
  tryIt("stat /data", () => fs.statSync("/data"));
  tryIt("readdir /data", () => fs.readdirSync("/data"));
  tryIt("stat /data/config.json", () => fs.statSync("/data/config.json"));
  tryIt("read /data/config.json", () => fs.readFileSync("/data/config.json", "utf8"));
'

probes() {
  docker run --rm --entrypoint sh -v f9338nfsvol:/data:nocopy "$PR" -c \
    'mount | sed -n "s/^\(.* on \/data type nfs4\) (\(rw\),.*\(vers=[0-9.]*\).*/  mount: \1 \2 \3/p"
     printf "  root, stat /data: "; stat -c "%u:%g %a" /data 2>&1
     printf "  root, cat config.json: "; cat /data/config.json 2>&1; echo
     printf "  uid 1001, stat /data: "; setpriv --reuid=1001 --regid=1001 --clear-groups stat -c "%u:%g %a" /data 2>&1
     printf "  uid 1001, cat config.json: "; setpriv --reuid=1001 --regid=1001 --clear-groups cat /data/config.json 2>&1; echo'
  for attempt in 1 2 3; do
    echo "  root, node, attempt $attempt:"
    docker run --rm --entrypoint node -v f9338nfsvol:/data:nocopy "$PR" -e "$PROBE"
    sleep 3
  done
  echo '  uid 1001, node:'
  docker run --rm --user 1001:1001 --entrypoint node -v f9338nfsvol:/data:nocopy "$PR" -e "$PROBE"
}

down() {
  docker container rm -f f9338 f9338nfs >/dev/null 2>&1
  docker volume rm -f f9338export f9338nfsvol f9338srv >/dev/null 2>&1
}

up() {
  down
  case $kind in
    ganesha)
      docker run -d --name f9338nfs --privileged -v f9338export:/export "$NFS" >/dev/null
      sleep 8
      addr=$(docker inspect f9338nfs --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
      device=:/export
      docker exec -e CONFIG="$CONFIG" f9338nfs sh -c \
        'printf "%s" "$CONFIG" > /export/config.json; chown -R 1001:1001 /export; chmod 700 /export; chmod 600 /export/config.json; stat -c "  on the NFS server: %u:%g %a %n" /export /export/config.json'
      ;;
    host)
      addr=${HOST_ADDR:?}
      device=:$HOST_DIR
      sudo env CONFIG="$CONFIG" DIR="$HOST_DIR" sh -c \
        'rm -rf "$DIR"/* "$DIR"/.[!.]* 2>/dev/null; printf "%s" "$CONFIG" > "$DIR/config.json"; chown -R 1001:1001 "$DIR"; chmod 700 "$DIR"; chmod 600 "$DIR/config.json"; stat -c "  on the NFS server: %u:%g %a %n" "$DIR" "$DIR/config.json"'
      ;;
  esac
  docker volume create --driver local --opt type=nfs --opt "o=addr=$addr,nfsvers=4.2,rw,soft,timeo=50,retrans=2,noac" --opt "device=$device" f9338nfsvol >/dev/null
}

case $kind in
  ganesha) ;;
  host)
    HOST_ADDR=${2:?address of the NFS server}
    HOST_DIR=${3:?exported folder}
    case $HOST_DIR in */f9338export) ;; *) echo "the exported folder must end in /f9338export" >&2; exit 2 ;; esac
    ;;
  *) echo "usage: actual-9338-nfs-probe.sh ganesha | host <address> <folder>" >&2; exit 2 ;;
esac

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "NFS server: $kind"
echo "host: $([ -r /etc/os-release ] && . /etc/os-release; echo "${PRETTY_NAME:-$(uname -s)}"), kernel $(uname -r)"
echo "docker: $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'), storage driver $(docker info --format '{{.Driver}}')"
for image in "$PR" "$V2"; do
  echo "image: $image $(docker image inspect "$image" --format '{{.Id}}'), entrypoint sha256 $(docker run --rm --entrypoint sha256sum "$image" /usr/local/bin/docker-entrypoint.sh | cut -c1-64)"
done

say "P. Probes on the export ($kind)"
up
probes

say "3e. NFS root squash, serverFiles on an empty root-owned volume, $PR ($kind)"
up
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$PR"

say "3f. NFS root squash, serverFiles on an empty root-owned volume, $V2 ($kind)"
up
run -v f9338nfsvol:/data:nocopy -v f9338srv:/srv/actual "$V2"
running && docker exec f9338 stat -c '  owner: %u:%g %a %n' /srv/actual /srv/actual/server-files 2>&1
sign_in_check

if [ "$kind" = ganesha ]; then
  say 'Last lines of the NFS server log'
  docker logs --tail 15 f9338nfs 2>&1 | cut -c1-220 | sed 's/^/  /'
fi

say 'cleanup'
down
docker ps -a --filter name=f9338 --format '{{.Names}}' | sed 's/^/  left over container: /'
docker volume ls --filter name=f9338 --format '{{.Name}}' | sed 's/^/  left over volume: /'
echo "done: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
