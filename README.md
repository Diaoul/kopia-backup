# Kopia Backup
Minimalist kopia backup with systemd.

This repository aims to provide simple and working example of how to run kopia
with systemd on a laptop. There is no notification service beyond a desktop
`notify-send`, no complex installation scripts, just a few files easy to
maintain and edit as required.

It is assumed that you know your way around both [kopia](https://kopia.io/) and
[systemd](https://www.freedesktop.org/wiki/Software/systemd/).

Kopia can schedule snapshots itself, but only from `kopia server` or KopiaUI,
and it cannot tell whether the machine is on battery or away from the
repository. Systemd timers can, so they do the scheduling here and kopia does
everything else: excludes, retention, compression and maintenance all live in
the repository.

## Installation
Install the scripts and the systemd units with:
```bash
sudo make install
sudo systemctl daemon-reload
```

Install the policy example with:
```bash
sudo make install-conf
```
**Warning:** this will overwrite any previous `/etc/kopia/policy.json`!

The Makefile honors the `DESTDIR` environment variable so if you want to
install it somewhere else to test things out, just run:
```bash
DESTDIR=/tmp/test make install
```

`sudo make uninstall` removes the scripts and units, and leaves `/etc/kopia`
alone.

## Configuration
Kopia connects to a repository once and stores the connection in a config file.
The units use `/etc/kopia/repository.config`. As root, once, create the
repository, or use `connect` instead of `create` to join an existing one:

```bash
read -rs -p 'Access key: ' AWS_ACCESS_KEY_ID && echo
read -rs -p 'Secret key: ' AWS_SECRET_ACCESS_KEY && echo
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
sudo --preserve-env=AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY \
    kopia repository create s3 \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia \
    --bucket my-bucket \
    --cache-directory /var/cache/kopia \
    --no-check-for-updates \
    --persist-credentials \
    --no-use-keyring
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

For an S3-compatible store other than AWS, such as Garage or MinIO, add
`--endpoint host:port` and the `--region` it expects: Garage rejects any region
but its configured one, `garage` by default. `create` refuses a bucket that
already holds data.

Kopia prompts for the repository password, which encrypts the repository and
is separate from the bucket credentials: lose it and the backups are
unreadable, so keep it in a password manager. Do not pass secrets as
`--access-key`, `--secret-access-key` or `--password`: arguments end up in your
shell history, in `ps` for anyone on the machine, and in the journal, since
sudo logs the full command line.

That single command writes everything the units need:

* the storage backend and its credentials, into the config file
* the cache directory, into the config file
* the repository password, into `/etc/kopia/repository.config.kopia-password`,
  mode 600, next to the config file

`--no-use-keyring` matters: the default is to put the password in the Gnome
keyring, which a system service cannot reach. `--persist-credentials` is what
writes the password sidecar instead.

`--no-check-for-updates` sticks too, in the sense that it stops kopia from
creating the `repository.config.update-info.json` sidecar it otherwise uses to
phone GitHub. Kopia writes other files next to the config as it runs, such as
`repository.config.mlock`, so do not be surprised by them.

Maintenance is owned by a single user, and it must be the one the units run as:
```bash
sudo kopia maintenance set --owner=me \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia
```

Edit the timers in `/etc/systemd/system/kopia-*.timer` to adjust the backup
frequency, and `kopia-backup.service` to change which paths are backed up.

## Policies
`/etc/kopia/policy.json` holds the global policy, in the format of
`kopia policy export`. Apply it after connecting, and again whenever you edit
it:

```bash
sudo kopia policy import \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia \
    --from-file /etc/kopia/policy.json
sudo kopia policy show --global \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia
```

The import touches only the policies in the file, here `(global)`. Policies you
set on individual sources stay as they are. Check the `policy show` output
after an edit: it is the only proof the file says what you meant.

Keep machine-specific excludes in the global list too, anchored to their
source, such as `/me/Downloads` for `/home/me/Downloads`. Excludes set on a
single source replace the global ones instead of adding to them, so a policy
on `/home` alone would quietly back up every `.cache` again.

What it sets:

* **Retention:** the latest 3 snapshots, 7 daily, 4 weekly and 6 monthly.
  Hourly and annual are set to 0, because kopia's defaults keep both.
* **Excludes:** gitignore syntax, matched against each snapshot source root
  rather than the filesystem root. A pattern with a slash is anchored to the
  source, so `/cache` is `/var/cache` for the `/var` source and `/*/.npm` is
  `~/.npm` for every user under `/home`. A pattern without one, such as
  `.cache`, matches at any depth. `.kopiaignore` files in the tree are honored
  as well, and directories with a `CACHEDIR.TAG` are skipped.
* **Compression:** `zstd`. Kopia does not compress by default. There is no best
  algorithm for every data set, and `kopia benchmark compression
  --data-file=<file>` compares them on yours.
* **One file system:** on, see below.

`oneFileSystem` deserves a look before you trust it. It stops at every mount
point, and the sources are exactly the places distributions like to mount
things under: `/var/log`, `/var/cache` and `/var/lib/*` are separate Btrfs
subvolumes on a stock Arch or openSUSE layout, and an encrypted or ZFS home is
its own filesystem. Anything mounted below a source is skipped, silently, with a
successful exit. Check what you actually have against the source list before
deciding:

```bash
findmnt -no TARGET | grep -E '^/(etc|home|root|usr/local|var)/'
```

Either add those paths as sources in `kopia-backup.service`, or set
`oneFileSystem` to `false` and lean on the excludes instead.

## Scheduling
A laptop is rarely in a backup-capable state at a fixed time of day: it may be
on battery, powered off, or away from the repository. Rather than pick one
instant and hope, the timers fire often and the services decide whether to run.

`kopia-backup.timer` fires at 05:00, 11:00, 17:00 and 23:00.
`kopia-backup.service` then runs only if all of the following hold:

* the machine is on AC power (`ConditionACPower`)
* the last successful backup is more than 20 hours old
* the repository is reachable

The last two are checked by `kopia-condition`, used as an `ExecCondition`. It
exits non-zero when a condition is not met, which systemd treats as *skip the
unit*, not *the unit failed*: no failed state, no `OnFailure`, no noise in
`systemctl --failed`. So there are four chances a day to catch a moment when
you are plugged in and within reach of the repository, and at most one backup
runs.

Reachability is checked with `kopia repository status` rather than a ping.
Opening the repository reads its format blob from the storage backend, so this
also covers the connection and the credentials.

Two more details worth knowing:

* `Persistent=true` catches up after the machine was off or asleep at every
  trigger point. It is safe here only because the service enforces its own
  minimum interval.
* `WakeSystem=false` is deliberate. It cannot be made conditional, because
  systemd arms the RTC alarm before `ConditionACPower` is evaluated: the
  machine would wake on battery only to skip. Backups happen while the laptop
  is awake instead.

`kopia-verify.timer` works the same way, on the first day of each quarter, with
a sixty day minimum interval.

## Maintenance
There is no maintenance unit, because kopia maintains the repository itself:
the maintenance owner runs quick maintenance about every hour and full
maintenance every 24 hours, as part of its ordinary commands. Here that means
the daily backup. Full maintenance is what deletes the data of expired
snapshots and reclaims the space.

Check when it last ran and when it is next due with:

```bash
sudo kopia maintenance info \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia
```

`kopia maintenance set --full-interval` changes the schedule.

## Monitoring
Skipped runs are normal here, so alerting per run is the wrong signal. What
matters is the age of the last success. Each service touches a timestamp in
`/var/lib/kopia` when it succeeds: `last-success-backup` and
`last-success-verify`.

`kopia-staleness` reads them and sends a desktop notification when one is
older than its threshold. It also warns when a timer is not enabled, and when a
unit has never succeeded, measured from when its timer was enabled so that a
fresh install is not reported stale before it was ever due. It runs as a user
unit, since `notify-send` needs the session bus. Enable it for every user:

```bash
sudo systemctl --global enable kopia-staleness.timer
```

or for yourself only:

```bash
systemctl --user enable --now kopia-staleness.timer
```

The thresholds are in `/etc/systemd/user/kopia-staleness.service`: 72 hours for
the backup and 2400 for verification. Pick thresholds that absorb how long you
are usually away, otherwise you will learn to ignore them.

Kopia's own notification profiles (`kopia notification profile configure
email`, `pushover` or `webhook`) complement this: they report errors and
snapshot results from the runs that happen, where `kopia-staleness` reports the
runs that did not.

## Verification
`kopia-verify.service` runs `kopia snapshot verify --verify-files-percent=100`
once a quarter. Without that flag, verification only checks that every object
referenced by the snapshots exists and that the metadata is consistent. With
it, every file is downloaded and hashed, so a blob that is present but corrupted
is caught too.

It downloads the whole repository, so mind your bandwidth and any egress fees.
Lower the percentage for a random sample instead, at the cost of never
guaranteeing full coverage. A backend that already scrubs and checksums, for
example a ZFS or Btrfs based NAS, makes this largely redundant.

Whatever you check, it is worth restoring something from time to time. A
repository that passes verification still tells you nothing about whether you
can get your data back out.

## Security
If your system is secure, you should also protect your backups. The two
sensitive files are written by `kopia repository create` or `connect`, not by
`make install-conf`: `/etc/kopia/repository.config` holds the backend
credentials and `/etc/kopia/repository.config.kopia-password` holds the
repository password. Kopia creates both mode 600 and owned by the user running
the connect, which should be root. Worth checking after the fact:

```bash
sudo ls -l /etc/kopia
```

### Sandboxing
The services run as root, because reading every file takes it, but sandboxed:
the filesystem is read-only apart from `/etc/kopia` and kopia's state, cache and
log directories, and the backup keeps only `CAP_DAC_READ_SEARCH`, which lets it
read any file and change none. Verification keeps no capabilities at all. The
log directory is mode 700, since kopia logs name every file it touches.

This set is tested on Arch with an S3 backend (Garage), not on every
distribution and layout. If a run fails with a permission or read-only error,
the journal names the path, and `systemd-analyze security kopia-backup.service`
shows what each line buys.

### Backups in a restored tree
One consequence of backing up `/etc`: the whole of `/etc/kopia` goes into the
repository along with everything else, and that is worth thinking about for a
moment.

The password sidecar is the mild half. Its presence in the snapshot does not
expose the repository, because the snapshot is encrypted with that very password
and reading it already requires knowing it. The backend credentials in
`repository.config` are the sharp half: they are stored in cleartext, and they
grant write and delete on the bucket, not just read. Anyone who can read a
restored copy of `/etc` can therefore destroy the backups, which is a strictly
worse outcome than reading them.

So treat any restored tree as sensitive. To keep `/etc/kopia` out of the
snapshots entirely, add this to the excludes in `policy.json`:

```
"/kopia/repository.config*"
```

The trade is that a bare metal restore then starts with `kopia repository
connect` typed by hand, which is only possible if the credentials survive
somewhere else. That is a password manager's job, not a backup's.

### Deletion and ransomware
Credentials scoped to the one bucket narrow the damage, but they cannot take
delete rights away: maintenance has to delete blobs to reclaim space, so
whoever holds the key can wipe the repository. What does protect against that
is object locking on the storage side, which kopia supports on S3 repositories
only. On a bucket created with Object Lock enabled, which MinIO supports as
well, create the repository with a retention mode and period, and let full
maintenance extend the locks on blobs still in use:

```bash
sudo kopia repository create s3 ... \
    --retention-mode COMPLIANCE \
    --retention-period 30d
sudo kopia maintenance set --extend-object-locks true \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia
```

Locked blobs cannot be deleted or overwritten until the period runs out, by
anyone: `COMPLIANCE`, which kopia strongly recommends, cannot be shortened even
by the bucket owner, where `GOVERNANCE` can be bypassed by a privileged
account. Kopia refuses to extend locks unless the full maintenance interval is
at least a day shorter than the period, and the locks only stay current while
full maintenance actually runs: pick a period longer than you are ever away
from the repository. Object locking is set when the bucket and the repository
are created, so an existing repository needs a new one.

Not every S3-compatible store implements Object Lock; Garage, for one, does
not. There the protection has to come from the storage host instead:
read-only filesystem snapshots of the store's data that the host itself
refuses to delete for a while, such as Synology's immutable snapshots, and an
offsite copy that keeps old versions. Snapshot the store's data and metadata
together, at a time when nothing is writing to it.

### Password at rest
The password sidecar is cleartext, protected by file permissions only. On a
machine with a TPM, `systemd-creds encrypt` can bind it to the machine instead:
load it with `LoadCredentialEncrypted=` and hand it to kopia as `KOPIA_PASSWORD`
from `$CREDENTIALS_DIRECTORY` through a small wrapper, then delete the sidecar.
The backend credentials stay in cleartext in `repository.config` either way,
so this only covers half of it.

## Usage
Enable and start the timers
```bash
sudo systemctl enable --now kopia-backup.timer
sudo systemctl enable --now kopia-verify.timer
```

Verify the status, e.g.
```bash
sudo systemctl list-timers
sudo systemctl status kopia-backup.service
```

For manual runs, point kopia at the same config file the units use:
```bash
sudo kopia --config-file /etc/kopia/repository.config snapshot list
```

That gets old fast, so a shell alias or a two line wrapper in `~/.local/bin` is
worth it.

To dump a database before each snapshot, look at kopia actions. They are off by
default and enabled with `--enable-actions` at connect time.

## Coming from restic
This started as a port of [restic-backup](https://github.com/Diaoul/restic-backup).
The scheduling is the same, the rest maps onto kopia like this:

* `--exclude-file` and `--keep-*` are not arguments: they are the repository
  policy in `policy.json`.
* `restic forget --prune` has no unit: kopia applies retention at every
  snapshot and maintains the repository itself.
* `restic check --read-data` is `snapshot verify --verify-files-percent=100`.
* `restic unlock` has no equivalent, there are no stale locks to clear.
* Tags do not scope retention in kopia. Every snapshot already records its
  `user@host:path`, which is what retention groups by.
