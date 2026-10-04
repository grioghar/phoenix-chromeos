#!/bin/sh
# phoenix rootshell on|off|status: let phoenix commands run from the browser terminal (crosh).
# crosh starts its shell with "no new privileges", so sudo cannot work there. Phoenix runs a private
# sshd on 127.0.0.1:2222 (key login only) and the phoenix command uses it automatically when sudo
# is blocked. Run "on" once from the VT2 console (Ctrl+Alt+F2), where sudo works.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
D=/etc/phoenix/ssh K=/home/chronos/.phoenix
rw(){ mount -o remount,rw / 2>/dev/null || true; }
ro(){ sync; mount -o remount,ro / 2>/dev/null || true; }
case "${1:-status}" in
  on)
    rw; mkdir -p $D; chmod 700 $D
    [ -f $D/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N "" -f $D/ssh_host_ed25519_key
    mkdir -p $K; chown chronos:chronos $K; chmod 700 $K
    # (ChromeOS has no su: create the key as root, then hand it to chronos)
    [ -f $K/root_key ] || ssh-keygen -q -t ed25519 -N "" -C phoenix-rootshell -f $K/root_key
    chown chronos:chronos $K/root_key $K/root_key.pub; chmod 600 $K/root_key
    cp $K/root_key.pub $D/root_authorized_keys; chmod 600 $D/root_authorized_keys
    cat > $D/sshd_config <<CFG
# Phoenix local root shell (see: phoenix rootshell)
Port 2222
ListenAddress 127.0.0.1
HostKey $D/ssh_host_ed25519_key
PermitRootLogin prohibit-password
AuthorizedKeysFile $D/root_authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
PidFile /run/phoenix-sshd.pid
CFG
    curl -s -m 20 "http://$H/svc/phoenix-rootssh.conf" -o /etc/init/phoenix-rootssh.conf.new && grep -q '^exec /usr/sbin/sshd' /etc/init/phoenix-rootssh.conf.new \
      && mv -f /etc/init/phoenix-rootssh.conf.new /etc/init/phoenix-rootssh.conf
    chcon --reference=/etc/init/shill.conf /etc/init/phoenix-rootssh.conf 2>/dev/null || true
    ro
    restart phoenix-rootssh 2>/dev/null || start phoenix-rootssh
    sleep 1
    if ssh -q -p 2222 -i $K/root_key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/phoenix-kh root@127.0.0.1 id -u 2>/dev/null | grep -q '^0$'; then
      echo "Root shell ready: phoenix commands now work in the browser terminal (Ctrl+Alt+T, then: shell)."
    else
      echo "The local root shell did not answer. Details:"
      status phoenix-rootssh 2>&1 | sed 's/^/  /'
      /usr/sbin/sshd -t -f $D/sshd_config 2>&1 | sed 's/^/  config: /'
      grep -E "sshd|phoenix-rootssh" /var/log/messages 2>/dev/null | tail -6 | sed 's/^/  log: /'
      exit 1
    fi
    ;;
  off)
    stop phoenix-rootssh 2>/dev/null || true
    rw; rm -f /etc/init/phoenix-rootssh.conf; rm -rf $D; rm -rf $K; ro
    echo "Local root shell removed."
    ;;
  *)
    status phoenix-rootssh 2>/dev/null || echo "phoenix-rootssh: not installed"
    [ -f $K/root_key ] && echo "key: $K/root_key" || echo "not set up (run: phoenix rootshell on, from VT2)"
    ;;
esac
