#!/usr/bin/env bash
# actualbudget/actual#9338, cases left open after the third pass:
#   M  the revised /app check when /proc/self/mountinfo can not be read
#   N  a read-only mount nested in the data folder
#   V  chown on a new, empty named volume, as the --user error message suggests
#
#   bash actual-9338-open-limits.sh > out.log 2>&1
#
# Images (override with environment variables):
#   PR   the PR head, built from sync-server.Dockerfile
#   V2   PR + the revised entrypoint (drafts/2026-11-18-actual-9338-entrypoint-v2.patch)
#   OLD  the last released image, which runs as root; used to make older data
#   TOOLS  any image with the openssl command, to make a test certificate
#
# Uses the container f9338m and volumes named f9338m*, and removes them at the
# end. Nothing is mounted from the host.
set -u
export MSYS_NO_PATHCONV=1

PR=${PR:-actual-pr9338:e9e7854}
V2=${V2:-f9338-patched3:local}
OLD=${OLD:-actualbudget/actual-server:26.10.0}
TOOLS=${TOOLS:-node:24-bookworm}

say() { printf '\n=== %s\n' "$*"; }
note() { printf -- '--- %s\n' "$*"; }

procs() {
  docker exec f9338m sh -c 'for p in /proc/[0-9]*; do n=$(sed -n "s/^Name:\t//p" $p/status 2>/dev/null); u=$(sed -n "s/^Uid:\t\([0-9]*\).*/\1/p" $p/status 2>/dev/null); echo "$n uid=$u"; done' 2>/dev/null |
    grep -E '^(MainThread|node) ' | sort -u | sed 's/^/  process: /'
}

settle() {
  for _ in $(seq 1 40); do
    [ "$(docker inspect f9338m --format '{{.State.Status}}')" = running ] || break
    docker logs f9338m 2>&1 | grep -q 'Listening on' && break
    sleep 1
  done
  sleep 2
}

report() {
  docker inspect f9338m --format '  state: {{.State.Status}}, exit code {{.State.ExitCode}}'
  docker logs f9338m 2>&1 | grep -E '^(Warning|Error|Set it|Give|Allow|Data from|to hand)|Listening on' | head -6 | sed 's/^/  log: /'
  procs
}

run() {
  docker container rm -f f9338m >/dev/null 2>&1
  printf '$ docker run %s\n' "$*"
  if ! docker run -d --name f9338m "$@" >/dev/null; then
    echo '  docker run failed'
    return
  fi
  settle
  report
}

restart() {
  echo '$ docker restart f9338m'
  docker restart f9338m >/dev/null
  sleep 2
  settle
  report
}

running() { [ "$(docker inspect f9338m --format '{{.State.Status}}' 2>/dev/null)" = running ]; }
owners() { running && docker exec f9338m stat -c '  owner: %u:%g %a %n' "$@" 2>&1; }

sign_in() {
  running || return 0
  docker exec f9338m node -e '
    const post = path => fetch("http://localhost:5006" + path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ password: "test-password-9338" }),
    });
    post("/account/bootstrap").then(() => post("/account/login")).then(async r => {
      const { data } = await r.json();
      console.log("  sign-in: HTTP " + r.status + (data?.token ? " with a token" : " without a token"));
    }).catch(e => console.log("  sign-in: failed " + (e.cause?.code || e.message)));
  ' 2>&1
}

clean() {
  docker container rm -f f9338m >/dev/null 2>&1
  docker volume rm -f f9338mdata f9338mapp f9338mstub f9338mro >/dev/null 2>&1
}

echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "docker: $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}') driver=$(docker info --format '{{.Driver}}')"
for image in "$PR" "$V2" "$OLD"; do
  echo "image: $image $(docker image inspect "$image" --format '{{.Id}}')"
done
echo "entrypoint in PR: $(docker run --rm --entrypoint sha256sum "$PR" /usr/local/bin/docker-entrypoint.sh | cut -c1-64)"
echo "entrypoint in V2: $(docker run --rm --entrypoint sha256sum "$V2" /usr/local/bin/docker-entrypoint.sh | cut -c1-64)"
clean

###########################################################################
say 'M. Revised check with /proc/self/mountinfo unreadable'
###########################################################################
# A preload makes reading that one file fail with EACCES, in every node process
# of the container, the one in the entrypoint included.
docker volume create f9338mstub >/dev/null
docker run --rm -i --entrypoint sh -v f9338mstub:/stub "$V2" -c 'cat > /stub/no-mountinfo.js' <<'EOF'
const fs = require("fs");
const read = fs.readFileSync;
fs.readFileSync = function (file, ...rest) {
  if (file === "/proc/self/mountinfo") {
    throw Object.assign(new Error("EACCES: permission denied, open " + file), { code: "EACCES" });
  }
  return read.call(this, file, ...rest);
};
EOF
STUB='-e NODE_OPTIONS=--require=/stub/no-mountinfo.js -v f9338mstub:/stub:ro'
PROBE='try { require("fs").readFileSync("/proc/self/mountinfo", "utf8"); console.log("read") } catch (e) { console.log("failed with " + e.code) }'

say 'M0. The preload works: reading /proc/self/mountinfo in node'
printf '  without the preload: '; docker run --rm --entrypoint node "$V2" -e "$PROBE"
printf '  with the preload:    '
# shellcheck disable=SC2086
docker run --rm $STUB --entrypoint node "$V2" -e "$PROBE"

say 'M1. Older root-owned data in a volume at /app/server-files'
run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338mdata:/data -v f9338mapp:/app/server-files "$OLD"
sign_in
owners /app/server-files /app/server-files/account.sqlite
note 'V2 with the preload'
# shellcheck disable=SC2086
run $STUB -e ACTUAL_SERVER_FILES=/app/server-files -v f9338mdata:/data -v f9338mapp:/app/server-files "$V2"
owners /app/server-files /app/server-files/account.sqlite
sign_in
note 'V2 without the preload, same volumes (control)'
run -e ACTUAL_SERVER_FILES=/app/server-files -v f9338mdata:/data -v f9338mapp:/app/server-files "$V2"
owners /app/server-files /app/server-files/account.sqlite
sign_in
docker container rm -f f9338m >/dev/null 2>&1
docker volume rm -f f9338mdata f9338mapp >/dev/null 2>&1

say 'M2. V2 with the preload, ACTUAL_SERVER_FILES=/app/node_modules'
# shellcheck disable=SC2086
run $STUB -e ACTUAL_SERVER_FILES=/app/node_modules "$V2"
owners /app/node_modules

say 'M3. V2 with the preload, default settings, new volume at /data'
# shellcheck disable=SC2086
run $STUB -v f9338mdata:/data "$V2"
sign_in
docker container rm -f f9338m >/dev/null 2>&1
docker volume rm -f f9338mdata >/dev/null 2>&1

say 'M4. V2 with the preload, new folder /app/server-files (no volume), then a restart'
# shellcheck disable=SC2086
run $STUB -e ACTUAL_SERVER_FILES=/app/server-files "$V2"
owners /app/server-files
sign_in
restart
owners /app/server-files
clean

###########################################################################
say 'N. A read-only mount nested in the data folder'
###########################################################################
# A self-signed key and certificate, readable by everyone, owned by root.
make_certs() {
  docker volume rm -f f9338mro >/dev/null 2>&1
  docker volume create f9338mro >/dev/null
  docker run --rm --entrypoint openssl -v f9338mro:/certs "$TOOLS" req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj /CN=localhost -keyout /certs/key.pem -out /certs/cert.pem >/dev/null 2>&1 || echo '  openssl failed'
  docker run --rm --entrypoint sh -v f9338mro:/certs "$PR" -c 'chmod 644 /certs/*.pem 2>/dev/null; chown -R "$0" /certs; stat -c "  owner: %u:%g %a %n" /certs /certs/*' "$1"
}
HTTPS='-e ACTUAL_HTTPS_KEY=/data/certs/key.pem -e ACTUAL_HTTPS_CERT=/data/certs/cert.pem'

for image in "$PR" "$V2"; do
  say "N1. $image: folder of certificates mounted read-only at /data/certs, root-owned, HTTPS settings point into it"
  make_certs 0:0
  docker volume rm -f f9338mdata >/dev/null 2>&1
  # shellcheck disable=SC2086
  run $HTTPS -v f9338mdata:/data -v f9338mro:/data/certs:ro "$image"
  owners /data /data/certs /data/certs/key.pem

  say "N2. $image: as N1, the folder and files owned by uid 1001"
  make_certs 1001:1001
  docker volume rm -f f9338mdata >/dev/null 2>&1
  # shellcheck disable=SC2086
  run $HTTPS -v f9338mdata:/data -v f9338mro:/data/certs:ro "$image"
  owners /data /data/certs /data/certs/key.pem

  say "N3. $image: the same folder mounted read-only outside the data folder, at /certs (control)"
  make_certs 0:0
  docker volume rm -f f9338mdata >/dev/null 2>&1
  run -e ACTUAL_HTTPS_KEY=/certs/key.pem -e ACTUAL_HTTPS_CERT=/certs/cert.pem -v f9338mdata:/data -v f9338mro:/certs:ro "$image"

  say "N4. $image: the two files mounted read-only one by one at /data/key.pem and /data/cert.pem"
  docker volume rm -f f9338mdata >/dev/null 2>&1
  run -e ACTUAL_HTTPS_KEY=/data/key.pem -e ACTUAL_HTTPS_CERT=/data/cert.pem -v f9338mdata:/data \
    --mount type=volume,src=f9338mro,dst=/data/key.pem,volume-subpath=key.pem,readonly \
    --mount type=volume,src=f9338mro,dst=/data/cert.pem,volume-subpath=cert.pem,readonly "$image"
  owners /data /data/key.pem
done
clean

###########################################################################
say 'V. chown on a new, empty named volume, then --user'
###########################################################################
say 'V1. PR image, new volume: chown -R 1000:1000 /data in a helper container, then --user 1000:1000'
docker run --rm --entrypoint sh -v f9338mdata:/data "$PR" -c 'chown -R 1000:1000 /data; stat -c "  in the helper, after chown: %u:%g %a %n" /data; ls -A /data | wc -l | sed "s/^/  entries in \/data: /"'
docker run --rm --entrypoint stat -v f9338mdata:/data "$PR" -c '  in the next container: %u:%g %a %n' /data
run --user 1000:1000 -v f9338mdata:/data "$PR"
docker volume rm -f f9338mdata >/dev/null 2>&1

say 'V2. As V1, with a file in the volume before the chown'
docker container rm -f f9338m >/dev/null 2>&1
docker run --rm --entrypoint sh -v f9338mdata:/data "$PR" -c 'touch /data/.keep; chown -R 1000:1000 /data; stat -c "  in the helper, after chown: %u:%g %a %n" /data'
docker run --rm --entrypoint stat -v f9338mdata:/data "$PR" -c '  in the next container: %u:%g %a %n' /data
run --user 1000:1000 -v f9338mdata:/data "$PR"
sign_in
docker container rm -f f9338m >/dev/null 2>&1
docker volume rm -f f9338mdata >/dev/null 2>&1

say 'V3. As V1, with the volume mounted :nocopy for the --user start'
docker run --rm --entrypoint sh -v f9338mdata:/data:nocopy "$PR" -c 'chown -R 1000:1000 /data; stat -c "  in the helper, after chown: %u:%g %a %n" /data'
run --user 1000:1000 -v f9338mdata:/data:nocopy "$PR"
sign_in

say 'cleanup'
clean
docker ps -a --filter name=f9338m --format '{{.Names}}' | sed 's/^/  left over container: /'
docker volume ls --filter name=f9338m --format '{{.Name}}' | sed 's/^/  left over volume: /'
echo 'done'
