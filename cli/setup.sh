#!/bin/sh
# Installs the `phoenix` command into /usr/bin (and `vostro` as an alias)
set -e
curl -s http://HOST:8099/vostro -o /tmp/phoenix
mount -o remount,rw / 2>/dev/null || true
# replace via rename: overwriting in place would corrupt a running "phoenix update"
cp /tmp/phoenix /usr/bin/phoenix.new && chmod 755 /usr/bin/phoenix.new && mv -f /usr/bin/phoenix.new /usr/bin/phoenix
ln -sfn phoenix /usr/bin/vostro.new && mv -Tf /usr/bin/vostro.new /usr/bin/vostro
mount -o remount,ro / 2>/dev/null || true
echo "Installed. Commands: phoenix fix | platform | detect | hostname | save | diag | install  (vostro still works)"
