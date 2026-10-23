#!/usr/bin/env bash
# End-to-end tests for keyswitch, against a real pass and GnuPG.
#
# Everything happens in a throwaway folder with its own HOME, GNUPGHOME and
# password store, so your own keys are never touched.
#
#   tests/run.sh                        uses `pass` from PATH
#   PASS=/path/to/pass tests/run.sh     uses that pass
#
# Needs: bash, gpg, pass (and its tree/getopt), curl; python3 for the HTTP
# check tests (skipped without it).

set -u

here=$(cd "$(dirname "$0")/.." && pwd)
KS=$here/bin/keyswitch
CHECK_HTTP=$here/bin/keyswitch-check-http
PASS_BIN=${PASS:-$(command -v pass || true)}
if [[ -z $PASS_BIN || ! -x $PASS_BIN ]]; then
  echo "tests need pass: install it, or run with PASS=/path/to/pass" >&2
  exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/keyswitch-test.XXXXXX")
SERVER_PID=''
cleanup() {
  if [[ -n $SERVER_PID ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  GNUPGHOME=$T/gnupg gpgconf --kill gpg-agent >/dev/null 2>&1
  GNUPGHOME=$T/gnupg gpgconf --remove-socketdir >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

export HOME=$T/home
export GNUPGHOME=$T/gnupg
unset PASSWORD_STORE_DIR XDG_CONFIG_HOME XDG_STATE_HOME GPG_TTY \
  KEYSWITCH_PASS KEYSWITCH_SERVICE KEYSWITCH_CONFIG_DIR KEYSWITCH_STATE_DIR
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
mkdir -p "$HOME" "$GNUPGHOME" "$T/pathbin"
chmod 700 "$HOME" "$GNUPGHOME"
umask 022

# `pass` on PATH for the default lookup.
ln -s "$PASS_BIN" "$T/pathbin/pass"
export PATH="$T/pathbin:$PATH"

# ------------------------------------------------------------ test helpers

n_ok=0
n_fail=0
OUT=''
ERR=''
RC=0

run() {
  OUT=$("$@" 2>"$T/stderr")
  RC=$?
  ERR=$(cat "$T/stderr")
}

check() {
  local desc=$1
  shift
  if "$@"; then
    n_ok=$((n_ok + 1))
    printf 'ok   %s\n' "$desc"
  else
    n_fail=$((n_fail + 1))
    printf 'FAIL %s\n' "$desc"
    printf '     rc=%s\n     stdout: %s\n     stderr: %s\n' "$RC" "${OUT//$'\n'/$'\n'             }" "${ERR//$'\n'/$'\n'             }"
  fi
}

rc_is() { [[ $RC == "$1" ]]; }
out_has() { [[ $OUT == *"$1"* ]]; }
out_lacks() { [[ $OUT != *"$1"* ]]; }
err_has() { [[ $ERR == *"$1"* ]]; }
out_is() { [[ $OUT == "$1" ]]; }
file_is() { [[ -f $1 && ! -L $1 && $(cat "$1") == "$2" ]]; }
file_lacks() { [[ ! -f $1 ]] || ! grep -q -- "$2" "$1"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mode_is() { [[ $(mode_of "$1") == "$2" ]]; }

CFG=$HOME/.config/keyswitch
TARGET=$HOME/.config/svc/key.dat

# Folders on the path to the pass under test that others can change (on S3DF,
# /sdf/group/lcls is group-writable). The tests trust them through
# trusted_dirs, as a user would; the trust checks themselves are tested on
# folders the tests create.
untrusted_dirs_of() {
  local cur='' part info mode gid
  local -a parts=()
  IFS=/ read -r -a parts <<<"$(dirname "$1")"
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    cur=$cur/$part
    info=$(stat -L -c '%a %g' "$cur" 2>/dev/null || stat -L -f '%Lp %g' "$cur")
    mode=${info% *}
    gid=${info#* }
    if (( 8#$mode & 8#1000 )); then continue; fi
    if (( 8#$mode & 8#002 )) || { (( 8#$mode & 8#020 )) && [[ $gid != 0 ]]; }; then
      printf '%s\n' "$cur"
    fi
  done
}
TRUSTED=$( { untrusted_dirs_of "$PASS_BIN"; untrusted_dirs_of "$(readlink -f "$PASS_BIN")"; } | sort -u | paste -sd: - )

# Write the global config: trusted_dirs (plus $EXTRA_TRUSTED), then any lines given.
write_global() {
  local t=$TRUSTED
  if [[ -n ${EXTRA_TRUSTED:-} ]]; then t=${t:+$t:}$EXTRA_TRUSTED; fi
  mkdir -p "$CFG"
  {
    if [[ -n $t ]]; then echo "trusted_dirs = $t"; fi
    if (( $# )); then printf '%s\n' "$@"; fi
  } > "$CFG/config"
}

# A service file with a given check line.
svc_with_check() {
  mkdir -p "$CFG"
  cat > "$CFG/svc.conf" <<EOF
entries = svc/
target  = ~/.config/svc/key.dat
check   = $1
EOF
}

write_svc() {
  mkdir -p "$CFG"
  cat > "$CFG/svc.conf" <<EOF
# test service
entries = svc/
target  = ~/.config/svc/key.dat
check   = '$T/check.sh'

message = Restart the demo to use it.
EOF
}

# ------------------------------------------------------------ fixtures

gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'keyswitch test <test@invalid>' default default never >/dev/null 2>&1 \
  || { echo "could not create a test GnuPG key" >&2; exit 2; }
FPR=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')

pass init "$FPR" >/dev/null 2>&1
add() { printf '%s\n' "$2" | pass insert -m "$1" >/dev/null; }
add svc/personal 'sk-test-personal-0001'
add svc/proj $'sk-test-project-0002\nuser: someone'
add svc/bad 'sk-test-bad-0003'
add svc/offline 'sk-test-offline-0004'
add svc/short 'short'
add other/one 'sk-test-other-0005'

# A fake check: accepts sk-test-* keys except "bad" (reject) and "offline"
# (cannot check). It records its own command line so we can prove the key
# never travels there.
cat > "$T/check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$0 \$*" >> "$T/check-argv"
env >> "$T/check-env"
if [ -e /proc/self/fd/9 ]; then echo open >> "$T/fd9"; fi
IFS= read -r key
case \$key in
  *bad*) echo "fake check: rejected" >&2; exit 1 ;;
  *offline*) echo "fake check: unreachable" >&2; exit 7 ;;
  sk-test-*|short) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$T/check.sh"

# ------------------------------------------------------------ basics

run "$KS" --version
check "--version works" rc_is 0
run "$KS" --help
check "--help describes 'use'" out_has "use NAME"
run "$KS"
check "no command is a usage error (exit 2)" rc_is 2
run "$KS" frobnicate
check "unknown command is a usage error (exit 2)" rc_is 2
run "$KS" list
check "no services yet gives a clear error" err_has "no services configured"

write_svc
write_global

# ------------------------------------------------------------ list / use / current

run "$KS" list
check "list shows stored keys" out_has "personal"
check "list says nothing is in use yet" out_has "none in use"
run "$KS" current
check "current with no key file exits 1" rc_is 1

run "$KS" use personal
check "use personal succeeds" rc_is 0
check "use prints the service message" out_has "Restart the demo to use it."
check "target holds exactly the key" file_is "$TARGET" "sk-test-personal-0001"
check "target is mode 600" mode_is "$TARGET" 600
check "a target folder it creates is mode 700" mode_is "$(dirname "$TARGET")" 700
check "the check got the key on stdin, never on its command line" file_lacks "$T/check-argv" "sk-test"
run "$KS" current
check "current prints personal" out_is "personal"
run "$KS" list
check "list marks the key in use with * and its last four characters" out_has "* personal"
check "list shows the hint" out_has "…0001"

run "$KS" use proj
check "use proj succeeds" rc_is 0
check "only the first line of a multi-line entry is written" file_is "$TARGET" "sk-test-project-0002"

run "$KS" use bad
check "a key the check rejects fails" rc_is 1
check "rejection is reported" err_has "rejected"
check "a rejected key leaves the target unchanged" file_is "$TARGET" "sk-test-project-0002"

run "$KS" use offline
check "a check that cannot run blocks the switch" rc_is 1
check "it suggests --allow-unchecked" err_has "--allow-unchecked"
check "the target is unchanged" file_is "$TARGET" "sk-test-project-0002"
run "$KS" use bad --allow-unchecked
check "--allow-unchecked still refuses a key the check rejects" rc_is 1
check "so the target is unchanged" file_is "$TARGET" "sk-test-project-0002"
run "$KS" use offline --allow-unchecked
check "--allow-unchecked switches when the check cannot run" file_is "$TARGET" "sk-test-offline-0004"

run "$KS" use missing
check "an unknown key name fails" rc_is 1
check "the error lists the available keys" err_has "personal"
run "$KS" use ../escape
check "a path-like name is a usage error" rc_is 2
run "$KS" use -x
check "a dash name is treated as an option (usage error)" rc_is 2
run "$KS" list --allow-unchecked
check "--allow-unchecked outside 'use' is a usage error" rc_is 2

: > "$T/check-env"
run env key=x content=x out=x SECRET=x TARGET_KEY=x "$KS" use personal
check "use works when the caller exported names keyswitch uses" rc_is 0
check "those names never carry the key into the check's environment" file_lacks "$T/check-env" "sk-test"
run env TARGET_KEY=x "$KS" test
check "nor does 'test'" file_lacks "$T/check-env" "sk-test"

mkdir -p "$HOME/.password-store/svc/locked"
chmod 000 "$HOME/.password-store/svc/locked"
run "$KS" use missing
check "an unreadable store folder does not hide the real error" err_has "no key named 'missing'"
chmod 755 "$HOME/.password-store/svc/locked"
rmdir "$HOME/.password-store/svc/locked"

run "$KS" use short
run "$KS" list
check "short keys show no hint" out_lacks "…"

echo "hand-edited" > "$TARGET"
run "$KS" current
check "current notices a hand-edited target" rc_is 1
check "and says why" err_has "was changed after"

# ------------------------------------------------------------ target edge cases

printf 'shared-key\n' > "$T/shared.dat"
chmod 644 "$T/shared.dat"
rm -f "$TARGET"
ln -s "$T/shared.dat" "$TARGET"
run "$KS" use personal
check "use replaces a symlinked target" rc_is 0
check "it warns about the symlink" err_has "symlink"
check "the target is now a regular file with the key" file_is "$TARGET" "sk-test-personal-0001"
check "the file the symlink pointed to is untouched" file_is "$T/shared.dat" "shared-key"

mkdir "$T/somedir"
rm -f "$TARGET"
ln -s "$T/somedir" "$TARGET"
run "$KS" use personal
check "a symlink to a folder is replaced, not followed" file_is "$TARGET" "sk-test-personal-0001"
check "nothing was written into that folder" [ -z "$(ls -A "$T/somedir")" ]

rm -f "$TARGET"
mkdir "$TARGET"
run "$KS" use personal
check "a real folder at the target path is refused" err_has "is a folder"
rmdir "$TARGET"

run "$KS" use proj
: > "$T/notadir"
run env KEYSWITCH_STATE_DIR="$T/notadir" "$KS" use personal
check "a broken state folder fails before the key file changes" file_is "$TARGET" "sk-test-project-0002"

chmod g+w "$(dirname "$TARGET")"
run "$KS" use personal
check "a key folder others can change is refused" err_has "can be changed by other users"
chmod 700 "$(dirname "$TARGET")"

chmod g+w "$T/check.sh"
run "$KS" use personal
check "a check program others can change is refused" err_has "the check program"
chmod 755 "$T/check.sh"

mkdir -p "$T/badpass"
cp "$PASS_BIN" "$T/badpass/pass"
chmod 775 "$T/badpass/pass"
run env KEYSWITCH_PASS="$T/badpass/pass" "$KS" use personal
check "a pass program others can change is refused" err_has "the pass program"
chmod 755 "$T/badpass/pass"
chmod 775 "$T/badpass"
run env KEYSWITCH_PASS="$T/badpass/pass" "$KS" use personal
check "so is one in a folder others can change" err_has "can be changed by other users"
check "and the error points at trusted_dirs" err_has "trusted_dirs"
chmod 755 "$T/badpass"

# The layout of a shared install: a group-writable folder holding a
# 'current' symlink, which anyone in the group could repoint.
mkdir -p "$T/shared/v1/bin"
ln -s "$PASS_BIN" "$T/shared/v1/bin/pass"
ln -s v1 "$T/shared/current"
chmod 775 "$T/shared"
run env KEYSWITCH_PASS="$T/shared/current/bin/pass" "$KS" use personal
check "a program below a folder others can change is refused, symlinks or not" err_has "trusted_dirs"
EXTRA_TRUSTED=$T/shared write_global
run env KEYSWITCH_PASS="$T/shared/current/bin/pass" "$KS" use personal
check "it is accepted once that folder is in trusted_dirs" rc_is 0
run "$KS" doctor
check "doctor lists the trusted folders" out_has "$T/shared"
write_global

# ------------------------------------------------------------ where pass comes from

run env KEYSWITCH_PASS=/nonexistent/pass "$KS" use personal
check "a bad KEYSWITCH_PASS fails" rc_is 1
check "and names KEYSWITCH_PASS" err_has "KEYSWITCH_PASS"
run env KEYSWITCH_PASS=no-such-pass "$KS" use personal
check "a bare name is looked up on PATH" err_has "cannot find 'no-such-pass' on PATH"

write_global 'pass = /nonexistent/pass'
run "$KS" use personal
check "a bad 'pass =' fails and names the config file" err_has "pass in ~/.config/keyswitch/config"
run env KEYSWITCH_PASS="$PASS_BIN" "$KS" use personal
check "KEYSWITCH_PASS wins over the config file" rc_is 0

# shellcheck disable=SC2016
write_global 'pass = ${KS_TEST_PASS}'
run env KS_TEST_PASS="$PASS_BIN" "$KS" use proj
check "\${VAR} in a value is expanded" rc_is 0
run "$KS" use proj
check "an unset \$VAR is an error, not a guess" err_has "KS_TEST_PASS, which is not set"
run env KS_TEST_PASS= "$KS" use proj
check "an empty \$VAR is an error too" err_has "not set or is empty"
write_global

run "$KS" doctor
check "doctor passes with a healthy setup" rc_is 0
check "doctor shows pass came from PATH" out_has "default (PATH)"

# ------------------------------------------------------------ config file rules

write_svc
echo "colour = blue" >> "$CFG/svc.conf"
run "$KS" use personal
check "an unknown setting still works" rc_is 0
check "but is warned about" err_has "unknown setting 'colour'"

write_svc
echo "entries = again/" >> "$CFG/svc.conf"
run "$KS" use personal
check "a setting given twice is an error" err_has "set twice"

write_svc
echo "garbage" >> "$CFG/svc.conf"
run "$KS" use personal
check "a line without '=' is an error with its line number" err_has "svc.conf:7:"

write_svc
chmod g+w "$CFG/svc.conf"
run "$KS" use personal
check "a config file others can change is refused" err_has "can be changed by other users"
chmod g-w "$CFG/svc.conf"
chmod g+w "$CFG"
run "$KS" use personal
check "a config folder others can change is refused" err_has "can be changed by other users"
chmod g-w "$CFG"

svc_with_check "'$T/check.sh'; true"
run "$KS" use personal
check "a check with a shell operator is refused" err_has "is not allowed"
svc_with_check "'$T/check.sh' \$HOME"
run "$KS" use personal
check "a check with a \$ is refused" err_has "is not allowed"
svc_with_check "./check.sh"
run "$KS" use personal
check "a relative check program is refused" err_has "relative path"
cp "$T/check.sh" "$HOME/check.sh"
# shellcheck disable=SC2088 # the ~ is for keyswitch to expand, not the shell
svc_with_check "~/check.sh"
run "$KS" use personal
check "a check starting with ~/ means your home folder" rc_is 0
svc_with_check "'~/check.sh'"
run "$KS" use personal
check "a quoted ~ is not expanded (so it is a relative path)" err_has "relative path"
svc_with_check "bash '$T/check.sh'"
run "$KS" use personal
check "an interpreter with a script works" rc_is 0
chmod g+w "$T/check.sh"
run "$KS" use personal
check "the script is vetted too, not just the interpreter" err_has "given to the check"
chmod 755 "$T/check.sh"
write_svc

# ------------------------------------------------------------ which pass store

PASSWORD_STORE_DIR=$T/store2 pass init "$FPR" >/dev/null 2>&1
printf 'sk-test-store2-0009\n' | PASSWORD_STORE_DIR=$T/store2 pass insert -m svc/personal >/dev/null
run env PASSWORD_STORE_DIR="$T/store2" "$KS" use personal
check "PASSWORD_STORE_DIR picks the store" file_is "$TARGET" "sk-test-store2-0009"
echo "store_dir = ~/.password-store" >> "$CFG/svc.conf"
run env PASSWORD_STORE_DIR="$T/store2" "$KS" use personal
check "store_dir in the service file wins over PASSWORD_STORE_DIR" file_is "$TARGET" "sk-test-personal-0001"
write_svc

# ------------------------------------------------------------ a $ in HOME

H2="$T/h\$x"
mkdir -p "$H2/.config/keyswitch"
chmod 700 "$H2"
cat > "$H2/.config/keyswitch/svc.conf" <<EOF
entries = svc/
target = ~/key.dat
store_dir = $HOME/.password-store
EOF
if [[ -n $TRUSTED ]]; then echo "trusted_dirs = $TRUSTED" > "$H2/.config/keyswitch/config"; fi
run env HOME="$H2" x=EVIL "$KS" use personal
check "a \$ inside HOME is not expanded again" file_is "$H2/key.dat" "sk-test-personal-0001"
check "nothing went to the expanded name" [ ! -e "$T/hEVIL" ]

# ------------------------------------------------------------ several services

cat > "$CFG/other.conf" <<EOF
entries = other
target = \${HOME}/.config/other/key.dat
EOF
run "$KS" use personal
check "with several services and no choice, use asks for one" err_has "several services"
run "$KS" -s svc use personal
check "-s picks the service" rc_is 0
run env KEYSWITCH_SERVICE=other "$KS" use one
check "KEYSWITCH_SERVICE picks the service" file_is "$HOME/.config/other/key.dat" "sk-test-other-0005"
run "$KS" list
check "list shows every service" out_has "other:"
write_global 'default_service = svc'
run "$KS" use proj
check "default_service picks the service" file_is "$TARGET" "sk-test-project-0002"
write_global

# ------------------------------------------------------------ add

pshow() { pass show "$1" 2>/dev/null | head -n 1; }
run bash -c "printf 'sk-test-new-0006\n' | '$KS' -s svc add newkey"
check "add stores a new key" rc_is 0
check "in pass, in the service's folder" [ "$(pshow svc/newkey)" = sk-test-new-0006 ]
check "add without --use leaves the target alone" file_is "$TARGET" "sk-test-project-0002"
run bash -c "printf 'sk-test-again-0007\n' | '$KS' -s svc add newkey"
check "add refuses to replace an existing key" err_has "already exists"
check "and leaves it as it was" [ "$(pshow svc/newkey)" = sk-test-new-0006 ]

mkdir -p "$T/nodecrypt"
cat > "$T/nodecrypt/pass" <<EOF
#!/usr/bin/env bash
if [ "\$1" = show ]; then echo "decryption attempted" >&2; exit 9; fi
exec "$PASS_BIN" "\$@"
EOF
chmod 755 "$T/nodecrypt/pass"
run bash -c "printf '  sk-test-new2-0008  \n' | KEYSWITCH_PASS='$T/nodecrypt/pass' '$KS' -s svc add newkey --force --use"
check "add --force --use replaces the key and starts using it" file_is "$TARGET" "sk-test-new2-0008"
check "without decrypting anything" [ "${ERR#*decryption attempted}" = "$ERR" ]
check "and drops pasted spaces" [ "$(pshow svc/newkey)" = sk-test-new2-0008 ]
run "$KS" -s svc current
check "current names the added key" out_is "newkey"

run bash -c "printf 'sk-test-bad-0011\n' | '$KS' -s svc add bad2"
check "add refuses a key the check rejects" rc_is 1
check "and stores nothing" [ ! -e "$HOME/.password-store/svc/bad2.gpg" ]
run bash -c "printf 'sk-test-offline-0012\n' | '$KS' -s svc add off2"
check "add refuses when the check cannot run" rc_is 1
run bash -c "printf 'sk-test-offline-0012\n' | '$KS' -s svc add off2 --allow-unchecked"
check "unless --allow-unchecked is given" [ -e "$HOME/.password-store/svc/off2.gpg" ]
run bash -c "printf '\n' | '$KS' -s svc add empty"
check "add needs a key" err_has "no key given"
mkdir -p "$T/emptystore"
run bash -c "printf 'sk-test-x-0013\n' | PASSWORD_STORE_DIR='$T/emptystore' '$KS' -s svc add x"
check "add explains a store that is not set up" err_has "not set up yet"
run "$KS" -s svc use personal --use
check "--use outside 'add' is a usage error" rc_is 2

# ------------------------------------------------------------ test / doctor

run "$KS" -s svc test
check "test accepts the key in use" rc_is 0
run "$KS" -s svc test bad
check "test NAME reports a rejected key (exit 1)" rc_is 1
run "$KS" -s svc test offline
check "test reports a check that cannot run (exit 3)" rc_is 3
run "$KS" -s other test
check "test without a configured check says so" err_has "has no 'check'"
check "test NAME does not switch" file_is "$TARGET" "sk-test-new2-0008"

chmod 644 "$TARGET"
run "$KS" doctor
check "doctor flags a key file others can read" out_has "readable by others"
check "and exits 1" rc_is 1
chmod 600 "$TARGET"
run env KEYSWITCH_PASS=/nonexistent/pass "$KS" doctor
check "doctor reports a missing pass program" out_has "✗"

# ------------------------------------------------------------ keyswitch-check-http

run "$CHECK_HTTP"
check "check-http without arguments exits 3" rc_is 3
run bash -c "printf 'k\n' | '$CHECK_HTTP' ftp://x x-api-key"
check "check-http refuses non-http URLs" rc_is 3
run bash -c "printf 'k\n' | '$CHECK_HTTP' http://example.com/ x-api-key"
check "check-http refuses plain http to another machine" err_has "refusing to send a key over plain http"
run bash -c "printf 'k\n' | '$CHECK_HTTP' http://localhost:1@example.com/ x-api-key"
check "check-http is not fooled by user@host tricks" err_has "refusing to send a key over plain http"
run bash -c "printf 'k\n' | '$CHECK_HTTP' https://x 'bad header'"
check "check-http refuses bad header names" rc_is 3
run bash -c "'$CHECK_HTTP' https://x x-api-key < /dev/null"
check "check-http needs a key on stdin" rc_is 3

if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/redir"):
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/" % self.server.server_address[1])
            self.end_headers()
            return
        ok = (self.headers.get("x-api-key") == "sk-good"
              or self.headers.get("Authorization") == "Bearer sk-good")
        self.send_response(200 if ok else 401)
        self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
' > "$T/port" &
  SERVER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $T/port ]] && break; sleep 0.2; done
  PORT=$(cat "$T/port")
  URL=http://127.0.0.1:$PORT/

  run bash -c "printf 'sk-good\n' | '$CHECK_HTTP' '$URL' x-api-key"
  check "check-http accepts a good key (exit 0)" rc_is 0
  run bash -c "printf 'sk-bad\n' | '$CHECK_HTTP' '$URL' x-api-key"
  check "check-http rejects a bad key (exit 1)" rc_is 1
  run bash -c "printf 'sk-good\n' | '$CHECK_HTTP' '$URL' Authorization 'Bearer '"
  check "check-http supports a value prefix" rc_is 0
  run bash -c "printf 'sk-good\n' | '$CHECK_HTTP' http://127.0.0.1:1/ x-api-key"
  check "check-http reports an unreachable URL (exit 3)" rc_is 3

  printf 'verbose\nlocation\nfail\n' > "$HOME/.curlrc"
  run bash -c "printf 'sk-good\n' | '$CHECK_HTTP' '${URL}redir' x-api-key"
  check "check-http ignores ~/.curlrc and never follows a redirect" rc_is 3
  check "and never prints the key, even with 'verbose' in ~/.curlrc" [ "${ERR#*sk-good}" = "$ERR" ]
  run bash -c "printf 'sk-bad\n' | '$CHECK_HTTP' '$URL' x-api-key"
  check "'fail' in ~/.curlrc cannot turn a rejection into 'could not check'" rc_is 1
  rm -f "$HOME/.curlrc"

  run bash -c "printf 'sk-good\n' | env -u NO_PROXY -u no_proxy http_proxy='http://127.0.0.1:$PORT/' '$CHECK_HTTP' http://127.0.0.1:1/ x-api-key"
  check "plain http to this machine never goes through a proxy" rc_is 3

  add web/good 'sk-good'
  add web/bad 'sk-bad'
  cat > "$CFG/web.conf" <<EOF
entries = web/
target = ~/.config/web/key
check = '$CHECK_HTTP' $URL x-api-key
EOF
  run "$KS" -s web use good
  check "end to end: a key the server accepts is written" file_is "$HOME/.config/web/key" "sk-good"
  run "$KS" -s web use bad
  check "end to end: a key the server rejects is not" file_is "$HOME/.config/web/key" "sk-good"
else
  echo "skip HTTP check tests (no python3)"
fi

check "the switch lock is never passed on to the check" [ ! -e "$T/fd9" ]

# ------------------------------------------------------------ summary

echo
echo "$n_ok passed, $n_fail failed"
(( n_fail == 0 ))
