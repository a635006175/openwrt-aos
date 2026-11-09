#!/bin/sh
# Copy this script, the .uc regression and prepare files to a router, then run sh.
# All writes are isolated; installed firewall rules and the live DB are unchanged.
set -eu
testdir=$(mktemp -d /tmp/console-situational-test.XXXXXX)
trap 'rm -rf "$testdir"' EXIT INT TERM
basedir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ucode -D testdir="$testdir" -D testsource="$basedir/console-situational-regression.uc" "$basedir/console-situational-prepare.uc"
sqlite3 "$testdir/test-security.db" "CREATE TABLE events(ts INTEGER,kind TEXT,rule TEXT,src TEXT,dst TEXT,proto TEXT,spt TEXT,dport TEXT,PRIMARY KEY(ts,src,rule,dport)) WITHOUT ROWID; CREATE INDEX events_ts ON events(ts); INSERT INTO events VALUES(strftime('%s','now')-29*86400,'threat','tin','1.1.1.1','192.168.1.1','TCP','1','80'); INSERT INTO events VALUES(strftime('%s','now')-31*86400,'threat','tin','1.0.0.1','192.168.1.1','TCP','1','80');"
ucode "$testdir/regression.uc"
