#!/bin/sh
# phoenix remote on|off|status: allow one trusted computer on your network to log in as root over
# SSH (for remote help/diagnostics). Builds on the local root shell (phoenix rootshell):
#  - the same private sshd, additionally listening on the network on port 2222
#  - only the trusted key below may log in, and only from the trusted address (from= restriction)
#  - the firewall opens port 2222 for that address only
# The key and address come from the Phoenix server's remote-access settings (never from the repo).
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
KEY='REMOTE_ACCESS_KEY'
FROM='REMOTE_ACCESS_FROM'
D=/etc/phoenix/ssh
rw(){ mount -o remount,rw / 2>/dev/null || true; }
ro(){ sync; mount -o remount,ro / 2>/dev/null || true; }
fw_on(){ iptables -C INPUT -p tcp -s "$FROM" --dport 2222 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$FROM" --dport 2222 -j ACCEPT; }
fw_off(){ while iptables -D INPUT -p tcp -s "$FROM" --dport 2222 -j ACCEPT 2>/dev/null; do :; done; }

case "${1:-status}" in
  on)
    case "$KEY" in ssh-*) ;; *) echo "The Phoenix server has no remote-access key configured."; exit 1;; esac
    if [ ! -f $D/sshd_config ] || ! status phoenix-rootssh 2>/dev/null | grep -q running; then
      echo "Setting up the local root shell first..."
      t=$(curl -fs "http://$H/rs") && sh -c "$t" phoenix-rootshell on || { echo "Remote access not enabled (local root shell failed)."; exit 1; }
    fi
    rw
    grep -v 'phoenix-remote' $D/root_authorized_keys > $D/ak.new || true
    echo "from=\"$FROM\",no-agent-forwarding,no-X11-forwarding $KEY phoenix-remote" >> $D/ak.new
    mv -f $D/ak.new $D/root_authorized_keys; chmod 600 $D/root_authorized_keys
    sed -i '/^ListenAddress 0.0.0.0/d' $D/sshd_config; echo "ListenAddress 0.0.0.0" >> $D/sshd_config
    touch /etc/phoenix/remote-on; echo "$FROM" > /etc/phoenix/remote-on
    ro
    restart phoenix-rootssh
    fw_on
    IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
    echo "Remote access ON: $FROM may now log in as root on $IP port 2222 (key only)."
    echo "Turn it off any time: phoenix remote off"
    ;;
  off)
    rw
    [ -f $D/root_authorized_keys ] && { grep -v 'phoenix-remote' $D/root_authorized_keys > $D/ak.new || true; mv -f $D/ak.new $D/root_authorized_keys; }
    [ -f $D/sshd_config ] && sed -i '/^ListenAddress 0.0.0.0/d' $D/sshd_config
    rm -f /etc/phoenix/remote-on
    ro
    fw_off
    restart phoenix-rootssh 2>/dev/null || true
    echo "Remote access OFF (the local root shell for the browser terminal is unchanged)."
    ;;
  *)
    if [ -f /etc/phoenix/remote-on ]; then echo "Remote access: ON for $(cat /etc/phoenix/remote-on)"; else echo "Remote access: off"; fi
    ;;
esac
