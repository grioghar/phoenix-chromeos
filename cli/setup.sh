#!/bin/sh
# Installs the `vostro` command into /usr/bin
set -e
curl -s http://HOST:8099/vostro -o /tmp/vostro
mount -o remount,rw / 2>/dev/null || true
# replace via rename: overwriting in place would corrupt a running "vostro update"
cp /tmp/vostro /usr/bin/vostro.new && chmod 755 /usr/bin/vostro.new && mv -f /usr/bin/vostro.new /usr/bin/vostro
mount -o remount,ro / 2>/dev/null || true
echo "Installed. From now on just type:  vostro fix   or   vostro diag"
