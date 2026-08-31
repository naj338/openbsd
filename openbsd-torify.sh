#!/bin/sh
#
# openbsd-torify.sh
#
# Routes this machine's traffic through Tor, using pf divert-to rules and
# Tor's TransPort/DNSPort.
#
# READ THIS FIRST
#
#   This is transparent torification on a single machine.  The Tor client,
#   your applications and your real IP all live in the same place, so
#   anything that gets past the pf rules leaks directly: a UDP protocol
#   that is not DNS, an ICMP probe, a browser exploit, an application that
#   ignores the system resolver.  The Tor Project recommends against this
#   arrangement for real anonymity -- Whonix or a separate gateway machine
#   are what actually isolate.  It is fine for "send my traffic through
#   Tor"; it is not fine for "my safety depends on this".
#
#   The rules are ordered to fail closed: block all comes first, so a
#   divert rule that does not match means no connectivity rather than a
#   silent leak.  Verify anyway -- see the tcpdump check at the end.
#
#   pf.conf and resolv.conf are replaced.  The originals are kept and
#   -r puts them back.
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
TRANS_PORT="9040"
DNS_PORT="5353"
VIRT_ADDR="10.192.0.0/10"
UPSTREAM_DNS="9.9.9.9"      # never actually reached; the query is diverted

msg()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat >&2 <<EOF
usage: $PROG [-l LAN] [-y] [-r]

    -l LAN   local network that should bypass Tor, e.g. 192.168.1.0/24.
             Detected from the default route if not given.
    -y       do not ask for confirmation before applying
    -r       revert: restore the saved pf.conf and resolv.conf, stop Tor
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
	for f in "$PFCONF" "$RESOLV" "$TORRC"; do
		if [ -f "$f.pretor" ]; then
			cp -p "$f.pretor" "$f"
			msg "restored $f"
		else
			warn "no saved copy of $f"
		fi
	done
	rcctl disable tor 2>/dev/null || true
	rcctl stop tor 2>/dev/null || true
	rcctl enable resolvd 2>/dev/null || true
	rcctl start resolvd 2>/dev/null || true
	pfctl -f "$PFCONF" && msg "pf reloaded"
	msg "done -- traffic is no longer going through Tor"
	exit 0
fi

# --------------------------------------------------------------- detect LAN --

EGRESS_IF="$(route -n show -inet 2>/dev/null |
	awk '$1 == "default" { print $NF; exit }')"
[ -n "$EGRESS_IF" ] || die "no default route; bring the network up first"

if [ -n "$LAN_OPT" ]; then
	LAN="$LAN_OPT"
else
	# derive the network from the interface address and netmask
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
msg "LAN that bypasses Tor: $LAN"

case "$LAN" in
10.*)
	warn "your LAN overlaps Tor's virtual address range $VIRT_ADDR."
	warn "  .onion traffic is diverted before the LAN bypass, so this"
	warn "  works, but keep the LAN as narrow as your real subnet."
	;;
esac

if [ "$ASSUME_YES" -eq 0 ]; then
	echo
	echo "This replaces $PFCONF and $RESOLV, and sends all TCP through Tor."
	echo "Anything that is not TCP or DNS gets dropped: ping stops working,"
	echo "and ntpd loses UDP time sync."
	echo "Undo with:  doas sh $PROG -r"
	printf 'Continue? [y/N]: '
	read -r ans || ans=""
	case "$ans" in
	[Yy]*) ;;
	*) msg "nothing changed"; exit 0 ;;
	esac
fi

# ------------------------------------------------------------------- install --

if ! pkg_info -e 'tor-*' >/dev/null 2>&1; then
	msg "installing tor"
	pkg_add -I tor </dev/null || die "could not install tor"
fi

save() {   # keep one pristine copy, the one -r restores
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

User _tor

# TransProxyType pf-divert tells tor to read the original destination with
# getsockname(2) instead of opening /dev/pf, so it never needs privileges
# on the firewall device.
TransPort 127.0.0.1:$TRANS_PORT
TransProxyType pf-divert

DNSPort 127.0.0.1:$DNS_PORT
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit
VirtualAddrNetworkIPv4 $VIRT_ADDR

# a plain SOCKS port as well, for anything you want to torify explicitly
SocksPort 127.0.0.1:9050
EOF
chmod 644 "$TORRC"

# ---------------------------------------------------------------------- pf ----

save "$PFCONF"
msg "writing $PFCONF"
cat >"$PFCONF" <<EOF
# generated by openbsd-torify.sh -- original saved as $PFCONF.pretor
#
# Order matters.  "block all" comes first and every pass is quick, so a
# rule that fails to match drops the packet instead of letting it out
# around Tor.  This fails closed by design.

tor_user   = "_tor"
trans_port = "$TRANS_PORT"
dns_port   = "$DNS_PORT"
virt_addr  = "$VIRT_ADDR"
lan        = "$LAN"

set skip on lo
match in all scrub (no-df random-id reassemble tcp)

block all

# Tor itself must reach the network directly, or nothing works
pass out quick proto tcp user \$tor_user

# DHCP, so the machine can still get a lease
pass out quick proto udp to port { 67 68 }
pass in  quick proto udp from port 67 to port 68

# .onion addresses are mapped into \$virt_addr, which sits inside 10/8 --
# divert them before the LAN bypass gets a chance to send them to the wire
pass out quick proto tcp to \$virt_addr divert-to 127.0.0.1 port \$trans_port

# the local network stays local
pass out quick to \$lan

# DNS goes to Tor's DNSPort
pass out quick proto udp to port domain divert-to 127.0.0.1 port \$dns_port

# everything else that is TCP goes through Tor
pass out quick proto tcp divert-to 127.0.0.1 port \$trans_port

# whatever is left -- other UDP, ICMP -- is dropped, not leaked
block out log all
EOF
chmod 600 "$PFCONF"

msg "checking the ruleset before loading it"
pfctl -nf "$PFCONF" || die "pf.conf did not parse; nothing was loaded"

# -------------------------------------------------------------------- DNS ----

# resolvd(8) rewrites resolv.conf from DHCP, which would undo this.
if rcctl ls on 2>/dev/null | grep -qx resolvd; then
	msg "disabling resolvd so it stops rewriting $RESOLV"
	rcctl stop resolvd 2>/dev/null || true
	rcctl disable resolvd
fi

save "$RESOLV"
msg "writing $RESOLV"
# This address is never contacted: the pf rule diverts udp/53 to Tor's
# DNSPort first.  It only has to be something off-machine, because
# "set skip on lo" means loopback traffic is never filtered or diverted.
cat >"$RESOLV" <<EOF
# generated by openbsd-torify.sh -- queries are diverted to Tor's DNSPort
nameserver $UPSTREAM_DNS
EOF
chmod 644 "$RESOLV"

# ------------------------------------------------------------------- apply ----

msg "enabling and starting tor"
rcctl enable tor
rcctl restart tor || die "tor would not start; check /var/log/daemon"

msg "loading the pf ruleset"
pfctl -f "$PFCONF"
pfctl -e 2>/dev/null || true

cat <<EOF

Done.  Now verify it, because a torified setup that silently is not
torified is worse than none.

  1. Confirm nothing leaves outside Tor.  This should stay silent:

         doas tcpdump -ni $EGRESS_IF not port 9001 and not port 443 and not tcp

  2. Confirm the exit is a Tor node:

         ftp -o - https://check.torproject.org/api/ip

  3. Watch what pf is dropping, if something stops working:

         doas tcpdump -ni pflog0

What breaks, expected:

  ping and traceroute      ICMP cannot go through Tor
  ntpd UDP time sync       switch /etc/ntpd.conf to https constraints;
                           Tor needs a correct clock to build circuits
  pkg_add                  slower, and some mirrors refuse Tor exits

To undo everything:

    doas sh $PROG -r

If you lose the network and cannot get a shell, boot to single user and
copy $PFCONF.pretor back over $PFCONF.

EOF
