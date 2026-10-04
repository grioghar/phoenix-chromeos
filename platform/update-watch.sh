#!/bin/sh
# Phoenix update watcher (phoenix-update service): make ChromeOS updates safe for this machine.
#
# ChromeOS downloads an update into the other system partition (ROOT-B) and marks it to boot next.
# Brunch then copies it over ROOT-A at the next boot and runs the Phoenix hook, which restores this
# machine's fixes from /mnt/stateful_partition/unencrypted/phoenix/bundles/<version>.tar.
# That rebuild runs without network, so the bundle for the NEW version must be here BEFORE reboot:
#   - update downloaded, bundle available  -> download + verify it into the store
#   - update downloaded, no bundle (yet)   -> HOLD the update: lower KERN-B's priority below KERN-A
#                                             so Brunch does not switch versions; release when ready
# State for `phoenix update-status`: /etc/phoenix/update-status
S=/mnt/stateful_partition/unencrypted/phoenix
ST=/var/lib/phoenix; mkdir -p $ST $S/bundles
SERVER=$(cat /etc/phoenix/server 2>/dev/null)
log(){ logger -t phoenix-update "$*"; echo "$(date '+%F %T') $*" > $ST/update-status; }
disk(){ rootdev -d -s; }

status=$(update_engine_client --status 2>/dev/null)
op=$(printf '%s\n' "$status" | sed -n 's/^CURRENT_OP=//p')
newv=$(printf '%s\n' "$status" | sed -n 's/^NEW_VERSION=//p')
curv=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release)

case "$op" in
  UPDATE_STATUS_UPDATED_NEED_REBOOT) ;;
  *) [ -f $ST/held ] || log "ChromeOS $curv; no update waiting (${op#UPDATE_STATUS_})"; exit 0 ;;
esac
[ -n "$newv" ] && [ "$newv" != "$curv" ] || exit 0

have(){ [ -s $S/bundles/$newv.tar ] && [ -s $S/bundles/$newv.sha256 ] && \
        [ "$(sha256sum < $S/bundles/$newv.tar | cut -d' ' -f1)" = "$(cut -d' ' -f1 $S/bundles/$newv.sha256)" ]; }

if ! have && [ -n "$SERVER" ]; then
  if curl -fs -m 20 "http://$SERVER/bundle/$newv.sha256" -o $S/bundles/$newv.sha256.new; then
    log "update $newv waiting: downloading its hardware-support bundle"
    curl -fs -m 3600 "http://$SERVER/bundle/$newv.tar" -o $S/bundles/$newv.tar.part \
      && mv -f $S/bundles/$newv.tar.part $S/bundles/$newv.tar && mv -f $S/bundles/$newv.sha256.new $S/bundles/$newv.sha256
  fi
  rm -f $S/bundles/$newv.sha256.new
fi

D=$(disk)
if have; then
  if [ -f $ST/held ]; then            # release a hold: give KERN-B back the priority update_engine set
    . $ST/held; cgpt add -i 4 -P "$prio" -T "$tries" -S 0 "$D" && rm -f $ST/held
    log "update $newv released: its bundle is ready; it installs at the next reboot"
  else
    log "update $newv ready: hardware support for it is saved; it installs at the next reboot"
  fi
else
  if [ ! -f $ST/held ]; then          # hold: Brunch only switches versions when KERN-B >= KERN-A
    pa=$(cgpt show -i 2 -P "$D"); pb=$(cgpt show -i 4 -P "$D"); tb=$(cgpt show -i 4 -T "$D")
    if [ "$pb" -ge "$pa" ]; then
      echo "prio=$pb tries=$tb version=$newv" > $ST/held
      cgpt add -i 4 -P 0 "$D"
    fi
  fi
  log "update $newv HELD: no hardware-support bundle for it yet; staying on $curv (checks every 10 minutes)"
fi
