#!/bin/sh
#
# openbsd-torify.sh
#
# Puts this machine's traffic through Tor.
#
# WHY THIS IS NOT A TRANSPARENT PROXY
#
#   pf's divert-to and rdr-to only apply to traffic arriving on an
#   interface.  They cannot touch connections the machine makes itself --
#   pfctl rejects the attempt outright with "divert-to used with outgoing
#   rule".  A box therefore cannot transparently intercept its own
#   outbound traffic; that needs a second machine acting as a gateway.
#
#   So this takes the other approach, which on one machine is both simpler
#   and safer:
#
#     * pf blocks every outbound packet except Tor's own, DHCP, and the
#       local network.  Nothing can reach the internet around Tor.
#     * Tor offers a SOCKS proxy, an HTTP tunnel, and a DNS port on
#       loopback, which loopback traffic reaches because pf skips lo.
#     * Applications are pointed at those.  Anything not pointed at them
#       simply has no network -- it fails closed rather than leaking.
#
#   That last property is the point.  A misconfigured application here
#   loses connectivity instead of quietly revealing your address.
#
#   This still is not strong anonymity: the Tor client, your applications
#   and your real address share one machine, so an application that can
#   be made to run code can still find you.  Whonix or a gateway box are
#   what actually isolate.
#
# Usage:  doas sh openbsd-torify.sh [-l LAN] [-y] [-r]
#
set -eu

PROG="${0##*/}"
LAN_OPT=""
ASSUME_YES=0
REVERT=0

TORRC="/etc/tor/torrc"
PFCONF="/etc/pf.conf"
RESOLV="/etc/resolv.conf"
PROFILE="/etc/profile"

SOCKS_PORT="9050"
HTTP_PORT="9080"
DNS_PORT="53"
VIRT_ADDR="10.192.0.0/10"

msg()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat >&2 <<EOF
usage: $PROG [-l LAN] [-y] [-r]

    -l LAN   local network that should stay local, e.g. 192.168.0.0/24.
             Detected from the default route if not given.
    -y       do not ask for confirmation
    -r       revert everything and stop Tor
EOF
	exit 1
}

while getopts l:yr opt; do
	case "$opt" in
	l) LAN_OPT="$OPTARG" ;;
	y) ASSUME_YES=1 ;;
	r) REVERT=1 ;;
	*) usage ;;
	esac
done

[ "$(uname -s)" = "OpenBSD" ] || die "this is OpenBSD-specific"
[ "$(id -u)" -eq 0 ] || die "run this as root (doas sh $PROG ...)"

# ------------------------------------------------------------------ revert --

if [ "$REVERT" -eq 1 ]; then
	msg "reverting"
	for f in "$PFCONF" "$RESOLV" "$TORRC" "$PROFILE"; do
		if [ -f "$f.pretor" ]; then
			cp -p "$f.pretor" "$f"
			msg "restored $f"
		else
			warn "no saved copy of $f"
		fi
	done
	rcctl stop tor 2>/dev/null || true
	rcctl disable tor 2>/dev/null || true
	rcctl set tor user '' 2>/dev/null || true
	rcctl enable resolvd 2>/dev/null || true
	rcctl start resolvd 2>/dev/null || true
	if pfctl -nf "$PFCONF" 2>/dev/null; then
		pfctl -f "$PFCONF"
		msg "pf reloaded"
	else
		warn "restored pf.conf does not parse; disabling pf instead"
		pfctl -d 2>/dev/null || true
	fi
	msg "done"
	exit 0
fi

# --------------------------------------------------------------- detect LAN --

EGRESS_IF="$(route -n show -inet 2>/dev/null |
	awk '$1 == "default" { print $NF; exit }')"
[ -n "$EGRESS_IF" ] || die "no default route; bring the network up first"

if [ -n "$LAN_OPT" ]; then
	LAN="$LAN_OPT"
else
	LAN="$(ifconfig "$EGRESS_IF" 2>/dev/null | awk '
		/inet .* netmask/ {
			split($2, a, ".")
			ip = a[1] * 16777216 + a[2] * 65536 + a[3] * 256 + a[4]
			m = $4; sub(/^0x/, "", m)
			bits = 0
			for (i = 1; i <= length(m); i++) {
				d = index("0123456789abcdef", substr(m, i, 1)) - 1
				while (d > 0) { if (d % 2) bits++; d = int(d / 2) }
			}
			# no bitwise AND in awk here, so mask by integer division
			block = 1
			for (i = 0; i < 32 - bits; i++) block = block * 2
			net = int(ip / block) * block
			printf "%d.%d.%d.%d/%d\n", int(net / 16777216) % 256, \
				int(net / 65536) % 256, int(net / 256) % 256, net % 256, bits
			exit
		}')"
	[ -n "$LAN" ] || die "could not work out the LAN; pass -l"
fi

msg "egress interface: $EGRESS_IF"
msg "LAN that stays local: $LAN"

if [ "$ASSUME_YES" -eq 0 ]; then
	cat <<EOF

This replaces $PFCONF, $RESOLV and appends to $PROFILE.

Afterwards, nothing reaches the internet except through Tor.  Programs
that are not pointed at the proxy lose their network rather than leaking:

    ping, traceroute        ICMP cannot go through Tor at all
    ntpd UDP time sync      switch /etc/ntpd.conf to https constraints
    anything without SOCKS  use torsocks, or it simply will not connect

Undo with:  doas sh $PROG -r
EOF
	printf 'Continue? [y/N]: '
	read -r ans || ans=""
	case "$ans" in
	[Yy]*) ;;
	*) msg "nothing changed"; exit 0 ;;
	esac
fi

# ------------------------------------------------------------------ install --

for p in tor torsocks; do
	if ! pkg_info -e "$p-*" >/dev/null 2>&1; then
		msg "installing $p"
		pkg_add -I "$p" </dev/null || warn "could not install $p"
	fi
done
[ -x /usr/local/bin/tor ] || die "tor is not installed"

save() {   # keep one pristine copy; -r restores from these
	if [ -f "$1" ] && [ ! -f "$1.pretor" ]; then
		cp -p "$1" "$1.pretor"
		msg "saved $1 as $1.pretor"
	fi
}

# --------------------------------------------------------------------- torrc --

save "$TORRC"
msg "writing $TORRC"
mkdir -p "$(dirname "$TORRC")"
cat >"$TORRC" <<EOF
# generated by openbsd-torify.sh

# Started as root so DNSPort can bind 53, then drops to _tor immediately.
User _tor

SocksPort 127.0.0.1:$SOCKS_PORT

# An HTTP CONNECT proxy, so ftp(1) and therefore pkg_add can use \$http_proxy.
HTTPTunnelPort 127.0.0.1:$HTTP_PORT

# System resolver goes here.  Names are resolved by Tor, not by your ISP.
DNSPort 127.0.0.1:$DNS_PORT
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit
VirtualAddrNetworkIPv4 $VIRT_ADDR
EOF
chmod 644 "$TORRC"

# Binding port 53 needs root at start-up; tor drops to _tor afterwards.
msg "setting tor to start as root so it can bind port $DNS_PORT"
rcctl set tor user root

# ---------------------------------------------------------------------- pf ----

save "$PFCONF"
msg "writing $PFCONF"
cat >"$PFCONF" <<EOF
# generated by openbsd-torify.sh -- original saved as $PFCONF.pretor
#
# Deny by default.  The only things that may leave are Tor itself, DHCP,
# and the local network.  Everything else has no route off this machine
# except through Tor's proxies on loopback, so a misconfigured program
# loses connectivity instead of leaking.

tor_user = "_tor"
lan      = "$LAN"

# loopback is where Tor's SOCKS, HTTP and DNS ports live
set skip on lo

match in all scrub (no-df random-id reassemble tcp)

block log all

# Tor's own connections to the network
pass out quick proto tcp user \$tor_user

# keep DHCP working
pass out quick proto udp to port { 67 68 }
pass in  quick proto udp from port 67 to port 68

# the local network stays reachable
pass out quick to \$lan
pass in  quick from \$lan

# everything else is dropped and logged
block out log all
EOF
chmod 600 "$PFCONF"

msg "checking the ruleset"
pfctl -nf "$PFCONF" || die "pf.conf did not parse; nothing was loaded"

# -------------------------------------------------------------------- DNS ----

if rcctl ls on 2>/dev/null | grep -qx resolvd; then
	msg "disabling resolvd so it stops rewriting $RESOLV"
	rcctl stop resolvd 2>/dev/null || true
	rcctl disable resolvd
fi

save "$RESOLV"
msg "writing $RESOLV"
cat >"$RESOLV" <<EOF
# generated by openbsd-torify.sh -- Tor's DNSPort, resolved over the network
nameserver 127.0.0.1
EOF
chmod 644 "$RESOLV"

# ---------------------------------------------------------------- http_proxy --

save "$PROFILE"
if ! grep -q 'openbsd-torify' "$PROFILE" 2>/dev/null; then
	msg "adding http_proxy to $PROFILE"
	cat >>"$PROFILE" <<EOF

# openbsd-torify.sh: send ftp(1), and so pkg_add, through Tor's HTTP tunnel
http_proxy=http://127.0.0.1:$HTTP_PORT/
https_proxy=\$http_proxy
export http_proxy https_proxy
EOF
fi

# ------------------------------------------------------------------- apply ----

msg "starting tor"
rcctl enable tor
if ! rcctl restart tor; then
	warn "tor would not start. Falling back to an unprivileged DNS port."
	sed -i "s|^DNSPort .*|DNSPort 127.0.0.1:9053|" "$TORRC"
	rcctl set tor user '' 2>/dev/null || true
	rcctl restart tor || die "tor still will not start; see /var/log/daemon"
	warn "DNS is on 9053, which resolv.conf cannot point at."
	warn "  System name lookups will fail; use torsocks, which resolves"
	warn "  through Tor by itself, or set your browser to SOCKS with"
	warn "  remote DNS enabled."
fi

msg "loading the pf ruleset"
pfctl -f "$PFCONF"
pfctl -e 2>/dev/null || true

cat <<EOF

Done.  Verify before trusting it.

  1. Nothing should leave outside Tor.  This should stay silent:

         doas tcpdump -ni $EGRESS_IF not tcp and not port 67 and not port 68

  2. Watch what pf drops, if something stops working:

         doas tcpdump -ni pflog0

  3. Confirm the exit node:

         ftp -o - https://check.torproject.org/api/ip

     (that works because \$http_proxy now points at Tor's HTTP tunnel;
      open a new shell first so /etc/profile is read)

Pointing programs at Tor:

  shell tools      torsocks <command>            e.g. torsocks ssh host
  ftp, pkg_add     already done via \$http_proxy
  browser          SOCKS5 host 127.0.0.1 port $SOCKS_PORT, and turn on
                   "proxy DNS when using SOCKS" or names leak to the
                   system resolver
  anything else    if it cannot do SOCKS, torsocks it, or it gets no
                   network at all -- which is the intended behaviour

To undo everything:

    doas sh $PROG -r

If you lose the network entirely and need it back immediately:

    doas pfctl -d

EOF
