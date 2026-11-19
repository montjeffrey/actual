#!/usr/bin/env bash
# actualbudget/actual#9338 on a Linux host, with folders of the host bind-mounted
# instead of named volumes:
#   B1-B3  a read-only folder or file inside the data folder (cases N1, N3, N4
#          of actual-9338-open-limits.sh)
#   B4-B5  chown on a new, empty data folder, then --user (case V1)
#
#   bash actual-9338-bind-mounts.sh > out.log 2>&1
#
# Needs a Linux host: on Docker Desktop a bind mount from Windows has no owners.
# Images (override with environment variables): PR, V2, TOOLS as in
# actual-9338-open-limits.sh. WORK is a new folder on the host; it is removed at
# the end. Uses the container f9338b.
set -u

PR=${PR:-actual-pr9338:e9e7854}
V2=${V2:-f9338-patched3:local}
TOOLS=${TOOLS:-node:24-bookworm}
WORK=${WORK:-$HOME/oss-lab/f9338b}
# The folder is emptied between cases, so only take one made for this script.
case $WORK in */f9338b) ;; *) echo "WORK must end in /f9338b" >&2; exit 2 ;; esac

say() { printf '\n=== %s\n' "$*"; }

procs() {
  docker exec f9338b sh -c 'for p in /proc/[0-9]*; do n=$(sed -n "s/^Name:\t//p" $p/status 2>/dev/null); u=$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" $p/status 2>/dev/null); echo "$n uid=$u"; done' 2>/dev/null |
    grep -E '^(MainThread|node) ' | sort -u | sed 's/^/  process: /'
}

settle() {
  for _ in $(seq 1 40); do
    [ "$(docker inspect f9338b --format '{{.State.Status}}')" = running ] || break
    docker logs f9338b 2>&1 | grep -q 'Listening on' && break
    sleep 1
  done
  sleep 2
}

run() {
  docker container rm -f f9338b >/dev/null 2>&1
  printf '$ docker run %s\n' "${*//$WORK/<work>}"
  if ! docker run -d --name f9338b "$@" >/dev/null; then
    echo '  docker run failed'
    return
  fi
  settle
  docker inspect f9338b --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  docker logs f9338b 2>&1 | grep -E '^(Warning|Error|Set it|Give|Allow|Data from|to hand)|Listening on' | head -6 | sed 's/^/  log: /'
  procs
}

running() { [ "$(docker inspect f9338b --format '{{.State.Status}}' 2>/dev/null)" = running ]; }

sign_in() {
  running || return 0
  docker exec f9338b node -e '
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    const base = (process.env.ACTUAL_HTTPS_KEY ? "https" : "http") + "://localhost:5006";
    const post = path => fetch(base + path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ password: "bind-mount-test-9338" }),
    });
    post("/account/bootstrap").then(() => post("/account/login")).then(async r => {
      const { data } = await r.json();
      console.log("  sign-in: HTTP " + r.status + (data?.token ? " with a token" : " without a token"));
    }).catch(e => console.log("  sign-in: failed " + (e.cause?.code || e.message)));
  ' 2>&1 | grep -v 'NODE_TLS_REJECT_UNAUTHORIZED\|node --trace-warnings'
}

# Owners as the host sees them.
host_owners() { (cd "$WORK" && stat -c '  on the host: %u:%g %a %n' "$@" 2>&1); }

# as_root <shell commands>: runs them as root in a helper container with the
# work folder at /w. Used to set owners and to empty the folder, without sudo.
as_root() { docker run --rm --entrypoint sh -v "$WORK:/w" "$PR" -c "$1"; }

fresh() {
  docker container rm -f f9338b >/dev/null 2>&1
  [ -d "$WORK" ] && as_root 'rm -rf /w/* /w/.[!.]*' 2>/dev/null
  mkdir -p "$WORK/data" "$WORK/certs"
}

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host: $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r), uid $(id -u)"
echo "docker: $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'), storage driver $(docker info --format '{{.Driver}}')"
echo "work folder: $(df -T "$(dirname "$WORK")" | tail -1 | awk '{print $2}') filesystem"
for image in "$PR" "$V2" "$TOOLS"; do
  echo "image: $image $(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || { docker pull -q "$image" >/dev/null && docker image inspect "$image" --format '{{.Id}}'; })"
done

make_certs() {
  docker run --rm --entrypoint openssl -v "$WORK/certs:/certs" "$TOOLS" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj /CN=localhost -keyout /certs/key.pem -out /certs/cert.pem >/dev/null 2>&1 || echo '  openssl failed'
  as_root 'chmod 644 /w/certs/*.pem'
}

for image in "$PR" "$V2"; do
  say "B1. $image: host folder at /data owned by 1001, folder of certificates bind-mounted read-only at /data/certs"
  fresh; make_certs
  as_root 'chown 1001:1001 /w/data; chown -R 0:0 /w/certs'
  host_owners data certs certs/key.pem
  run -e ACTUAL_HTTPS_KEY=/data/certs/key.pem -e ACTUAL_HTTPS_CERT=/data/certs/cert.pem \
    -v "$WORK/data:/data" -v "$WORK/certs:/data/certs:ro" "$image"
  sign_in

  say "B2. $image: the same folder bind-mounted read-only outside the data folder, at /certs (control)"
  fresh; make_certs
  as_root 'chown 1001:1001 /w/data; chown -R 0:0 /w/certs'
  run -e ACTUAL_HTTPS_KEY=/certs/key.pem -e ACTUAL_HTTPS_CERT=/certs/cert.pem \
    -v "$WORK/data:/data" -v "$WORK/certs:/certs:ro" "$image"
  sign_in

  say "B3. $image: the two files bind-mounted read-only one by one at /data/key.pem and /data/cert.pem"
  fresh; make_certs
  as_root 'chown 1001:1001 /w/data; chown -R 0:0 /w/certs'
  run -e ACTUAL_HTTPS_KEY=/data/key.pem -e ACTUAL_HTTPS_CERT=/data/cert.pem \
    -v "$WORK/data:/data" -v "$WORK/certs/key.pem:/data/key.pem:ro" -v "$WORK/certs/cert.pem:/data/cert.pem:ro" "$image"
  sign_in
done

say "B4. $PR: new, empty host folder owned by root, chown -R 1000:1000 in a helper container, then --user 1000:1000"
fresh
as_root 'chown 0:0 /w/data'
host_owners data
docker run --rm --entrypoint sh -v "$WORK/data:/data" "$PR" -c 'chown -R 1000:1000 /data; stat -c "  in the helper, after chown: %u:%g %a %n" /data'
docker run --rm --entrypoint sh -v "$WORK/data:/data" "$PR" -c 'stat -c "  in the next container: %u:%g %a %n" /data'
host_owners data
run --user 1000:1000 -v "$WORK/data:/data" "$PR"
sign_in

say "B5. $PR: new, empty host folder owned by root, --user 1000:1000 without the chown (control)"
fresh
as_root 'chown 0:0 /w/data'
run --user 1000:1000 -v "$WORK/data:/data" "$PR"

say 'cleanup'
docker container rm -f f9338b >/dev/null 2>&1
as_root 'rm -rf /w/* /w/.[!.]*' 2>/dev/null
rmdir "$WORK" 2>/dev/null
echo "left over: container [$(docker ps -a --filter name=f9338b --format '{{.Names}}' | tr '\n' ' ')] work folder [$(ls -d "$WORK" 2>/dev/null)]"
echo "done: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
