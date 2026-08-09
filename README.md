# Kopia Backup
Minimalist kopia backup with systemd.

This repository aims to provide simple and working example of how to run kopia
with systemd. There is no fancy notification, no complex installation scripts,
just a few files easy to maintain and edit as required.

It is assumed that you know your way around both [kopia](https://kopia.io/) and
[systemd](https://www.freedesktop.org/wiki/Software/systemd/).

## Installation
Install the systemd files with:
```bash
sudo make install
```

Install the configuration example with:
```bash
sudo make install-conf
```
**Warning:** this will overwrite any previous configuration!

The Makefile honors the `DESTDIR` environment variable so if you want to
install it somewhere else to test things out, just run:
```bash
DESTDIR=/tmp/test make install
```

## Configuration
Kopia is stateful where restic is not: instead of pointing at a repository URL
on every run, it connects once and stores the connection in a config file. The
units use `/etc/kopia/repository.config` and pass nothing through the
environment, so there is no `EnvironmentFile` here. Connect as root, once:

```bash
sudo kopia repository connect s3 \
    --config-file /etc/kopia/repository.config \
    --log-dir /var/log/kopia \
    --bucket my-bucket \
    --access-key ... \
    --secret-access-key ... \
    --password ... \
    --cache-directory /var/cache/kopia \
    --no-check-for-updates \
    --persist-credentials \
    --no-use-keyring
```

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
frequency.

Edit the services in `/etc/systemd/system/kopia-*.service` to change which
paths are backed up or the kopia arguments.

## Policies
Excludes, retention and most other knobs are not command line arguments in
kopia: they are policies stored inside the repository. `kopia-policy` applies
the global one, reading ignore rules from `/etc/kopia/excludes`. Run it after
connecting, and again whenever the excludes change:

```bash
sudo kopia-policy
```

Retention is `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`, the equivalent
of the `restic forget` arguments. Edit `kopia-policy` to change it. Note that
ignore rules are matched against each snapshot source root rather than the
filesystem root, so `/cache` is `/var/cache` for the `/var` source. Kopia also
honors `.kopiaignore` files in the tree, which the policy is free to ignore.

The policy also turns on `zstd` compression, which has no restic equivalent
here: restic compresses by default, kopia does not. Drop that flag if you back
up mostly incompressible data.

`--one-file-system` deserves a look before you trust it. It stops at every
mount point, and the sources above are exactly the places distributions like to
mount things under: `/var/log`, `/var/cache` and `/var/lib/*` are separate Btrfs
subvolumes on a stock Arch or openSUSE layout, and an encrypted or ZFS home is
its own filesystem. Anything mounted below a source is skipped, silently, with a
successful exit. Check what you actually have against the source list before
deciding:

```bash
findmnt -no TARGET | grep -E '^/(etc|home|root|usr/local|var)/'
```

Either add those paths as sources in `kopia-backup.service`, or turn the flag
off in `kopia-policy` and lean on the ignore rules instead.

`kopia-policy` diffs the excludes file against the rules already in the
repository and applies everything in one `policy set`, which is why it needs
`jq`. The obvious `--clear-ignore` followed by `--add-ignore` does not work:
in a single invocation the two cancel out, and split across two invocations a
failure in between leaves the repository with no ignore rules at all, so the
next scheduled snapshot quietly swallows every cache directory. Re-running it
is always safe, it converges and changes nothing when there is nothing to
change.

The snapshots are tagged `source:systemd`, which is only provenance. It does not
scope anything, unlike `restic forget --tag systemd`: retention comes from the
global policy and applies to every snapshot in the repository.

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

`kopia-maintenance.timer` works the same way, weekly, with a five day minimum
interval. Five rather than six: a run delayed by `RandomizedDelaySec`, or a
catch-up run landing a day late, would otherwise leave the next weekly trigger
a few minutes short of six days, skip, and turn a weekly clean up into a
fortnightly one without saying anything.

## Maintenance
There is no `kopia forget`. Snapshots that fall outside the retention policy
are marked for deletion when a new snapshot is created; what actually reclaims
the space is maintenance. `kopia maintenance run --full` does the snapshot
garbage collection and deletes unreferenced blobs, which is the counterpart of
`restic forget --prune`.

Kopia also runs quick maintenance opportunistically at the end of a snapshot,
unless it is disabled. That is fine to leave on: it only compacts indexes.

## Monitoring
Skipped runs are normal here, so alerting per run is the wrong signal. What
matters is the age of the last successful backup. The state files
`/var/lib/kopia/last-success-backup` and `/var/lib/kopia/last-success-maintenance`
are there for that. A user timer running something like this is enough:

```bash
threshold=72
stamp=/var/lib/kopia/last-success-backup
if [[ ! -f $stamp ]]; then
    notify-send -u critical "Backup never succeeded" "no $stamp"
else
    age=$(( ( $(date +%s) - $(stat -c %Y "$stamp") ) / 3600 ))
    (( age > threshold )) && notify-send -u critical "Backup stale" "${age}h since last backup"
fi
```

The missing file branch is not decoration. Without it `stat` prints nothing,
the arithmetic fails, and the two states that most deserve an alert, a backup
that never once succeeded and a wiped state directory, are the two that stay
silent.

Pick a threshold that absorbs how long you are usually away, otherwise you will
learn to ignore it.

## Verification
`kopia-maintenance.service` runs `kopia snapshot verify --verify-files-percent=1`
after every maintenance run. Without that flag, verification checks that every
object referenced by the snapshots exists and that the metadata is consistent,
which is roughly what `restic check` covers. It does not read the contents of
the pack blobs, so it cannot detect a blob that is present but corrupted.

`--verify-files-percent=1` additionally downloads and hashes a random 1% of the
files, so corruption is caught eventually rather than never. Eventually is the
right word: the sample is random on every run rather than a rotating slice, so
unlike `restic check --read-data-subset=1/8` it never guarantees full coverage,
it only makes undetected corruption increasingly unlikely. It costs a download
of that fraction, so pick a percentage that matches your bandwidth and how much
you trust the storage backend. A backend that already scrubs and
checksums, for example a ZFS or Btrfs based NAS, makes this largely redundant.

Whatever you check, it is worth restoring something from time to time. A
repository that passes verification still tells you nothing about whether you
can get your data back out.

## Security
If your system is secure, you should also protect your backups. The two
sensitive files are written by `kopia repository connect`, not by
`make install-conf`: `/etc/kopia/repository.config` holds the backend
credentials and `/etc/kopia/repository.config.kopia-password` holds the
repository password. Kopia creates both mode 600 and owned by the user running
the connect, which should be root. Worth checking after the fact:

```bash
sudo ls -l /etc/kopia
```

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

So treat any restored tree as sensitive, and prefer backend credentials scoped
to the one bucket, without lifecycle or delete rights if the provider allows it.
To keep `/etc/kopia` out of the snapshots entirely, add this to the excludes:

```
/kopia/repository.config*
```

The trade is that a bare metal restore then starts with `kopia repository
connect` typed by hand, which is only possible if the credentials survive
somewhere else. That is a password manager's job, not a backup's.

## Usage
Enable and start the timers
```bash
sudo systemctl enable --now kopia-backup.timer
sudo systemctl enable --now kopia-maintenance.timer
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

## Thanks
The restic version of this, from which everything here is derived:

* https://github.com/Diaoul/restic-backup
