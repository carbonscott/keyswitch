# keyswitch

Switch which key a program reads, keeping your keys encrypted in
[pass](https://www.passwordstore.org/).

Many tools read an API key from one fixed file. If you have more than one key
(a personal one, a project one, a new one replacing an old one), you end up
copying keys around by hand. keyswitch keeps every key in your own `pass`
store and, when you switch, writes the one you chose to that fixed file:

```
pass store (encrypted)          keyswitch use project            the file your tool reads
  myservice/personal   ──┐      1. decrypt with pass             ~/.config/myservice/key
  myservice/project    ──┼───▶  2. check it (optional)    ───▶   (mode 600, written atomically)
  myservice/old        ──┘      3. write it in one step
```

keyswitch is a thin layer over `pass`. It does not store keys itself, and
nothing about any particular service is built in: every path, the `pass`
program and the check command come from configuration, environment variables
or documented defaults, and `keyswitch doctor` shows which one won.

## Requirements

- bash, `pass` (1.7 or later) and GnuPG, set up the usual way (`pass init`)
- curl, only for the bundled `keyswitch-check-http`

## Install

```sh
make install PREFIX="$HOME/.local"    # installs keyswitch and keyswitch-check-http
```

Or copy the two scripts in `bin/` anywhere on your PATH.

## Quick start

```sh
# 1. Describe the service
mkdir -p -m 700 ~/.config/keyswitch
cat > ~/.config/keyswitch/myservice.conf <<'EOF'
entries = myservice/
target  = ~/.config/myservice/key
check   = keyswitch-check-http https://api.example.com/v1/models x-api-key
message = Restart mytool to use the new key.
EOF

# 2. Add your keys (each is checked, then stored in pass as myservice/NAME)
keyswitch add personal --use      # asks for the key, hidden; --use starts using it
keyswitch add project

# 3. Switch
keyswitch use project
keyswitch list
#     personal
#   * project                  …7f3a
```

## Commands

| Command | What it does |
|---|---|
| `keyswitch list` | Show your keys; `*` marks the one in use, with its last four characters |
| `keyswitch use NAME` | Decrypt `NAME` with pass, run the check, write it to the target file |
| `keyswitch add NAME` | Check a new key and store it in pass as `NAME`; `--use` also starts using it, `--force` replaces an existing one |
| `keyswitch current` | Print the name of the key in use (exit 1 if unknown) |
| `keyswitch test [NAME]` | Run the check on the key in use, or on `NAME` without switching |
| `keyswitch doctor` | Show every setting, where it came from, and any problems |

Options: `-s NAME` / `--service NAME` picks a service when several are
configured. `--allow-unchecked` makes `use` and `add` go ahead even when the
check cannot run (offline, timeout); a key the check rejects is still refused.

`add` reads the key hidden from the terminal, or the first line of stdin
(leading and trailing spaces are dropped), so scripts can pipe a key in. With
`--use` it writes the target from the key it was just given, so it needs no
passphrase. Keys stored with `pass insert` work too, as long as the secret is
on the first line. Removing and renaming keys is done with `pass` itself
(`pass rm`, `pass mv`).

## Configuration

Configuration lives in one folder:

1. `$KEYSWITCH_CONFIG_DIR`, if set
2. otherwise `$XDG_CONFIG_HOME/keyswitch`
3. otherwise `~/.config/keyswitch`

It holds an optional `config` file and one `NAME.conf` file per service.
Lines are `name = value`; comments go on their own line and start with `#`.
`pass`, `target`, `store_dir` and `trusted_dirs` may use `~` and `$VARS`; an
unset or empty variable is an error, never a guess. `check` has its own rules
(see below). `entries` and `message` are taken literally.

**`config`** (optional)

| Setting | Meaning |
|---|---|
| `pass` | The pass program to run, as a path or a command name |
| `default_service` | Service to use when none is given |
| `trusted_dirs` | Folders, separated by `:`, that other users can change but that you trust (see Security notes) |

**`NAME.conf`** (one per service)

| Setting | Required | Meaning |
|---|---|---|
| `entries` | yes | The pass folder holding this service's keys, e.g. `myservice/` |
| `target` | yes | The file your program reads its key from |
| `check` | no | A command that tests a key (see below) |
| `store_dir` | no | Which pass store to use |
| `message` | no | Text printed after a successful switch |

`entries` and `target` have no defaults on purpose: only you know where your
program reads its key, and a guess could put a key somewhere unexpected.

### Where each setting comes from

The first source that is set wins.

| Setting | 1st | 2nd | 3rd |
|---|---|---|---|
| pass program | `KEYSWITCH_PASS` | `pass =` in `config` | `pass` on PATH |
| service | `-s NAME` | `KEYSWITCH_SERVICE` | `default_service`, or the only service configured |
| pass store | `store_dir =` in the service file | `PASSWORD_STORE_DIR` (pass's own) | `~/.password-store` |
| state folder | `KEYSWITCH_STATE_DIR` | `$XDG_STATE_HOME/keyswitch` | `~/.local/state/keyswitch` |

The service file's `store_dir` outranks `PASSWORD_STORE_DIR` because it is
the more specific of the two: it names the store for this one service, while
`PASSWORD_STORE_DIR` is often set for everything you do with pass.

### The check command

`check` is one command with its arguments. It is split into words the way the
shell would split them: `'...'` and `"..."` group words, a backslash keeps the
next character, and `~` at the start of an unquoted word is your home folder.
Nothing else is expanded, and pipes, redirections, `;`, `&`, `$` and
backquotes are refused: put anything more complex in a script and point
`check` at it. keyswitch runs the command directly (no shell) with the key on
**stdin**, never on its command line. Its exit status means:

| Exit | Meaning | What `use` and `add` do |
|---|---|---|
| 0 | accepted | switches |
| 1 | rejected | refuses; nothing changes |
| anything else | could not check (offline, timeout...) | refuses; `--allow-unchecked` overrides |

`keyswitch-check-http URL HEADER [VALUE_PREFIX]` is a ready-made check for
HTTP APIs. It sends the key in a header (via `curl -H @-`, so again not on a
command line) and maps HTTP 2xx to accepted and 401/403 to rejected. It runs
curl with `-q`, so your `~/.curlrc` cannot change its behaviour; it never
follows redirects; and it only uses `https://`, except plain `http://` to the
local machine (`127.0.0.1`, `[::1]`, `localhost`), which never goes through a
proxy:

```
check = keyswitch-check-http https://api.example.com/v1/models x-api-key
check = keyswitch-check-http https://api.example.com/v1/models Authorization 'Bearer '
```

## Security notes

What keyswitch does:

- Keys you are not using stay encrypted in your pass store.
- The key in use is written with mode 600, through a temporary file that is
  flushed to disk and then renamed, so the target never holds a half-written
  key. A symlink at the target is replaced (even one pointing at a folder),
  never written through; a real folder there is refused.
- Keys are never passed on a command line or in environment variables, so
  they do not appear in `ps` output, shell history or child processes'
  environments.
- Two switches of the same service at once are serialized where `flock`
  exists (Linux).
- Only a short fingerprint and the last four characters of a key (for keys of
  12 characters or more) are recorded, so `current` and `list` can tell which
  key is in use without decrypting anything.
- Config files, the config folder, the folder holding the key file and the
  state folder must belong to you (or root) and not be writable by others.
- Every program that sees a key is vetted before it runs: `pass`, the check
  command, and every argument of the check that is an absolute path to a file
  (a script given to an interpreter). keyswitch walks every folder from `/`
  down to each of them, as written and with symlinks resolved, and refuses one
  that other users can change, since they could swap the program. Sticky
  folders such as `/tmp` are fine when the entry inside belongs to you or
  root, and folders writable by root's group are fine. The program file itself
  must not be writable by others. Owners may be anyone, as with any shared
  install; the vetted, resolved path is what runs. So vetting trusts whoever
  owns those folders: pointing `pass` or `check` at another person's files
  hands that person your keys.
- On shared systems a parent folder is often group-writable on purpose. If you
  trust everyone who can change it, list it in `trusted_dirs`; keyswitch then
  accepts that folder as it is. `keyswitch doctor` shows the list.

What it does not do:

- The key in use is a plain file. Anything running as you can read it, as it
  must for your program to work.
- Your pass store is only as strong as your GnuPG passphrase. A key with no
  passphrase protects nothing.
- Deleting a key with `pass rm` removes your copy only. It does not revoke
  the key with whoever issued it.
- The permission checks read classic Unix mode bits. They see POSIX ACLs
  through the mask (so a folder with an ACL may look group-writable even when
  only named users can write), but not NFSv4 or GPFS ACLs, which some shared
  filesystems use.
- A check's inline code (`bash -c ...`, `python3 -c ...`) cannot be
  inspected; only files named by absolute path are vetted.
- `--allow-unchecked` trusts a key that could not be checked; use it only
  when you know why the check cannot run.

## Development

```sh
make test     # end-to-end tests with a throwaway GnuPG key and pass store
make lint     # shellcheck
```

The tests never touch your own keys: they run with their own `HOME`,
`GNUPGHOME` and password store in a temporary folder. Use
`PASS=/path/to/pass make test` to test against a particular pass.
