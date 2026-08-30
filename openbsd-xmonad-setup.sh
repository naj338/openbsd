#!/bin/sh
#
# openbsd-xmonad-setup.sh
#
# Turns a stock OpenBSD install into an xmonad desktop with sway-style
# keybindings, started from a themed xenodm(1).
#
# Written against the OpenBSD 7.7+ package layout.  Things that shape the
# design:
#
#   1. x11/xmonad ships only /usr/local/bin/xmonad.  The Haskell library
#      packages are gone, so a custom xmonad.hs is compiled with ghc +
#      cabal-install against Hackage.  The first build takes a while.
#   2. OpenBSD enforces W^X.  Anything ghc/cabal builds and then executes
#      must live on a wxallowed(8) file system -- on a default install
#      that is /usr/local, not /home.  The cabal store, the build tree and
#      the compiled window manager live under /usr/local/xmonad/<user>,
#      and ~/.cache/xmonad is a symlink to it.  The editable config stays
#      in ~/.config/xmonad.
#   3. st and dmenu keep their colours in config.h, so both are built from
#      source.  st also gets the alpha patch for real transparency; if the
#      patch will not apply, picom's opacity-rule is used instead (which
#      fades the text as well as the background).
#
# Usage:  doas sh openbsd-xmonad-setup.sh -m "DP-1,HDMI-1" [-u user] ...
#
set -eu

PROG="${0##*/}"
TARGET_USER=""
OUTPUTS=""
SKIP_PKGS=0
SKIP_SRC=0
START_DM=0
FIX_WX=0

msg()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat >&2 <<EOF
usage: $PROG [-u user] [-m "OUT1,OUT2"] [-n] [-N] [-s] [-w]

    -u user  account to configure (default: \$SUDO_USER / \$DOAS_USER)
    -m list  monitor outputs in physical order, left to right, as they
             appear in 'xrandr -q'.  e.g. -m "DP-1,HDMI-1"
    -n       skip package installation
    -N       skip the st and dmenu source builds
    -s       start xenodm as soon as the script finishes
    -w       remount the file system holding /usr/local with wxallowed
             (not persistent -- edit /etc/fstab to make it stick)
EOF
	exit 1
}

while getopts u:m:nNsw opt; do
	case "$opt" in
	u) TARGET_USER="$OPTARG" ;;
	m) OUTPUTS="$OPTARG" ;;
	n) SKIP_PKGS=1 ;;
	N) SKIP_SRC=1 ;;
	s) START_DM=1 ;;
	w) FIX_WX=1 ;;
	*) usage ;;
	esac
done

# =========================================================================
# Theme -- the single source of truth for every generated file.
#
# Anchored on the three Haskell logo purples: #453a62 (lambda), #5e5086
# and #8f4e8b (the bind arrows).  The remaining ANSI slots are tinted
# towards that palette but kept far enough apart that red errors and
# green diffs are still readable.
# =========================================================================

C_BG="#1c1826"          # background
C_BG_ALT="#2a2440"      # panels, inactive tabs
C_FG="#e8e4f0"          # foreground
C_DIM="#6c6483"         # empty workspaces, separators
C_HS_DARK="#453a62"     # Haskell lambda purple
C_HS_MID="#5e5086"      # Haskell bind purple
C_HS_MAG="#8f4e8b"      # Haskell bind magenta
C_ACCENT="#a88fd0"      # focus / current workspace
C_URGENT="#d9738f"      # urgent / failure

C_00="#1c1826"; C_08="#4a4360"
C_01="#b4506b"; C_09="#d9738f"
C_02="#6f9e6a"; C_10="#8fc088"
C_03="#c9a35b"; C_11="#e8c47a"
C_04="#5e5086"; C_12="#8b79c4"
C_05="#8f4e8b"; C_13="#c078bb"
C_06="#5f9ea0"; C_14="#86c5c7"
C_07="#cfc9de"; C_15="#f2eefa"

ST_ALPHA="0.78"
ST_OPACITY="78"
FONT_FALLBACK="DejaVu Sans Mono"
FONT_FAMILY="$FONT_FALLBACK"       # replaced below if Code New Roman lands

# One size for every font in the desktop, in points.  13pt is about 17px
# at 96dpi, so the bar and the tab decorations have to grow with it or the
# text gets clipped -- keep at least 12px of slack in both.
FONT_SIZE="13"
BAR_HEIGHT="32"                    # xmobar
DECO_HEIGHT="30"                   # xmonad tab bars

# Borders and gaps.  Both border colours are light purple so every window
# is outlined; the focused one is simply brighter.
C_BORDER="#8b79c4"                 # unfocused window border
BORDER_WIDTH="3"
GAP_OUTER="8"                      # between the tiling area and the screen
GAP_INNER="4"                      # around each window, so 8px between two

# Filled in once the font situation is known
XENODM_FONT=""
XENODM_GREET=""

# --------------------------------------------------------------- preflight --

[ "$(uname -s)" = "OpenBSD" ] || die "this only makes sense on OpenBSD"
[ "$(id -u)" -eq 0 ] || die "run this as root (doas sh $PROG ...)"

ARCH="$(uname -m)"
case "$ARCH" in
amd64 | arm64) ;;
*) die "x11/xmonad is only built for amd64 and arm64; this is $ARCH" ;;
esac

[ -x /usr/X11R6/bin/X ] || die "X is not installed (reinstall the x*.tgz sets)"
[ -x /usr/X11R6/bin/xenodm ] || die "xenodm is missing (reinstall the xserv/xbase sets)"

if [ -z "$TARGET_USER" ]; then
	TARGET_USER="${SUDO_USER:-${DOAS_USER:-}}"
fi
[ -n "$TARGET_USER" ] || die "no target user; pass -u <user>"
[ "$TARGET_USER" != "root" ] || die "refusing to configure root's desktop"
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

TARGET_GROUP="$(id -gn "$TARGET_USER")"
HOMEDIR="$(awk -F: -v u="$TARGET_USER" '$1 == u { print $9 }' /etc/master.passwd)"
[ -n "$HOMEDIR" ] && [ -d "$HOMEDIR" ] || die "no home directory for $TARGET_USER"

XM_ROOT="/usr/local/xmonad/$TARGET_USER"
SRC_ROOT="/usr/local/xmonad/src"
STAMP="$(date +%Y%m%d%H%M%S)"

msg "configuring xmonad for $TARGET_USER ($HOMEDIR) on $ARCH"

WX_MNT="$(df -k /usr/local | awk 'NR == 2 { print $NF }')"
if mount | grep -q "on $WX_MNT type .*wxallowed"; then
	msg "$WX_MNT is mounted wxallowed"
elif [ "$FIX_WX" -eq 1 ]; then
	msg "remounting $WX_MNT with wxallowed"
	mount -uo wxallowed "$WX_MNT"
	warn "not persistent -- add wxallowed to the $WX_MNT line in /etc/fstab"
else
	warn "$WX_MNT is not mounted wxallowed; ghc and cabal will fail with"
	warn "  'permission denied' when they exec what they just built."
	warn "  Fix:  mount -uo wxallowed $WX_MNT"
	warn "  and add wxallowed to its options in /etc/fstab so it survives a reboot."
	warn "  (Re-run with -w to have this script do the remount.)"
fi

AVAIL="$(df -k /usr/local | awk 'NR == 2 { print $4 + 0 }')"
if [ "${AVAIL:-0}" -lt 3000000 ]; then
	warn "less than 3G free on /usr/local; ghc plus the cabal store need roughly that"
fi

for dm in sddm gdm lightdm slim ly; do
	if rcctl ls on 2>/dev/null | grep -qx "$dm"; then
		warn "$dm is enabled and will fight xenodm -- 'rcctl disable $dm'"
	fi
done

if [ -n "$OUTPUTS" ]; then
	# best effort: root often cannot reach the user's display, so only
	# warn when xrandr actually answers
	if XR="$(DISPLAY="${DISPLAY:-:0}" xrandr -q 2>/dev/null)"; then
		for o in $(echo "$OUTPUTS" | tr ',' ' '); do
			if ! printf '%s\n' "$XR" | grep -q "^$o connected"; then
				warn "'$o' is not a connected output. xrandr reports:"
				printf '%s\n' "$XR" | grep ' connected' >&2
			fi
		done
	fi
else
	warn "no -m given, so the monitor order will not be corrected."
	warn "  Run 'xrandr -q' for your output names, then re-run with"
	warn "  -m \"LEFT,RIGHT\" -n -N  to write just the display configuration."
fi

# ---------------------------------------------------------------- packages --

if [ ! -f /etc/installurl ]; then
	msg "writing /etc/installurl"
	echo "https://cdn.openbsd.org/pub/OpenBSD" >/etc/installurl
fi

add_pkg() {
	if pkg_info -e "$1-*" >/dev/null 2>&1; then
		msg "$1 is already installed"
		return 0
	fi
	msg "installing $1"
	pkg_add -I "$1" </dev/null
}

if [ "$SKIP_PKGS" -eq 0 ]; then
	for p in xmonad ghc cabal-install gmake unzip; do
		add_pkg "$p" || die "could not install $p"
	done
	# picom is what makes the terminal transparency work at all; the rest
	# degrade gracefully if a package is missing.
	for p in picom xmobar xwallpaper; do
		add_pkg "$p" || warn "optional package $p was not installed"
	done
	# pkg_add can report success and still leave nothing on PATH, so check
	for b in gmake unzip ghc cabal; do
		command -v "$b" >/dev/null 2>&1 ||
			warn "$b is not on PATH after pkg_add -- try 'pkg_add $b' by hand"
	done
else
	msg "skipping package installation (-n)"
fi

# ------------------------------------------------------------------- fonts --

FONT_DIR="/usr/local/share/fonts/CodeNewRoman"
if [ "$SKIP_PKGS" -eq 0 ] && [ ! -d "$FONT_DIR" ]; then
	if ! command -v unzip >/dev/null 2>&1; then
		warn "unzip is missing, so Code New Roman cannot be unpacked."
		warn "  pkg_add unzip, then re-run with -n -N to pick it up."
	else
		msg "fetching Code New Roman (Nerd Fonts build)"
		mkdir -p "$FONT_DIR"
		if ftp -o "/tmp/cnr.$STAMP.zip" \
			"https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CodeNewRoman.zip"
		then
			unzip -qo "/tmp/cnr.$STAMP.zip" '*.ttf' -d "$FONT_DIR" || true
			rm -f "/tmp/cnr.$STAMP.zip"
			fc-cache -f "$FONT_DIR" >/dev/null 2>&1 ||
				fc-cache -f >/dev/null 2>&1 || true
		else
			warn "could not download Code New Roman; falling back to $FONT_FALLBACK"
			rmdir "$FONT_DIR" 2>/dev/null || true
		fi
	fi
fi

# Whatever actually landed decides the font name every config file uses.
if fc-list : family 2>/dev/null | grep -qi 'CodeNewRoman Nerd Font Mono'; then
	FONT_FAMILY="CodeNewRoman Nerd Font Mono"
elif fc-list : family 2>/dev/null | grep -qi 'Code New Roman'; then
	FONT_FAMILY="Code New Roman"
fi
msg "using font: $FONT_FAMILY"

# xenodm only understands Xft patterns if it was linked against libXft;
# otherwise it needs a core XLFD name.  Guessing wrong here means a login
# screen that cannot draw, so ask the binary rather than assume.
if ldd /usr/X11R6/bin/xenodm 2>/dev/null | grep -qi 'libXft'; then
	XENODM_FONT="$FONT_FAMILY:size=$FONT_SIZE"
	XENODM_GREET="$FONT_FAMILY:size=$((FONT_SIZE + 6)):bold"
	msg "xenodm has Xft; the greeter gets $FONT_FAMILY"
else
	XENODM_FONT="-*-dejavu sans mono-medium-r-normal--18-*-*-*-*-*-iso10646-1"
	XENODM_GREET="-*-dejavu sans mono-bold-r-normal--24-*-*-*-*-*-iso10646-1"
	warn "xenodm is not linked against Xft, so the greeter cannot use"
	warn "  $FONT_FAMILY. Falling back to a core DejaVu font."
fi

# =========================================================================
# Templating.  Every generated file goes through render(), so the palette
# and the font are defined in exactly one place.
# =========================================================================

render() {   # render <destination> <mode>;  template on stdin
	sed \
		-e "s|@FONT@|$FONT_FAMILY|g" \
		-e "s|@FSIZE@|$FONT_SIZE|g" \
		-e "s|@BARH@|$BAR_HEIGHT|g" \
		-e "s|@DECOH@|$DECO_HEIGHT|g" \
		-e "s|@BORDER@|$C_BORDER|g" \
		-e "s|@BORDERW@|$BORDER_WIDTH|g" \
		-e "s|@GAPOUT@|$GAP_OUTER|g" \
		-e "s|@GAPIN@|$GAP_INNER|g" \
		-e "s|@XFONT@|$XENODM_FONT|g" \
		-e "s|@XGREET@|$XENODM_GREET|g" \
		-e "s|@BG@|$C_BG|g" \
		-e "s|@BGALT@|$C_BG_ALT|g" \
		-e "s|@FG@|$C_FG|g" \
		-e "s|@DIM@|$C_DIM|g" \
		-e "s|@HSDARK@|$C_HS_DARK|g" \
		-e "s|@HSMID@|$C_HS_MID|g" \
		-e "s|@HSMAG@|$C_HS_MAG|g" \
		-e "s|@ACCENT@|$C_ACCENT|g" \
		-e "s|@URGENT@|$C_URGENT|g" \
		-e "s|@C00@|$C_00|g" -e "s|@C08@|$C_08|g" \
		-e "s|@C01@|$C_01|g" -e "s|@C09@|$C_09|g" \
		-e "s|@C02@|$C_02|g" -e "s|@C10@|$C_10|g" \
		-e "s|@C03@|$C_03|g" -e "s|@C11@|$C_11|g" \
		-e "s|@C04@|$C_04|g" -e "s|@C12@|$C_12|g" \
		-e "s|@C05@|$C_05|g" -e "s|@C13@|$C_13|g" \
		-e "s|@C06@|$C_06|g" -e "s|@C14@|$C_14|g" \
		-e "s|@C07@|$C_07|g" -e "s|@C15@|$C_15|g" \
		-e "s|@ALPHA@|$ST_ALPHA|g" \
		-e "s|@OPACITY@|$ST_OPACITY|g" \
		>"$1"
	chmod "$2" "$1"
}

backup() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		mv "$1" "$1.bak.$STAMP"
		warn "moved existing $1 aside to $1.bak.$STAMP"
	fi
}

# =========================================================================
# st and dmenu from source.
#
# Both keep their colours in config.h, so the packages are no use here.
# The approach is deliberately conservative: take upstream's config.def.h
# and surgically replace the font line and the colour array, rather than
# shipping a whole config.h that might not match that version's x.c.
# =========================================================================

ST_PATCHED=0

# OpenBSD's ftp(1) prints "Trying .../Requesting ..." on stdout, so a
# function whose output is captured must keep it quiet (-V) and return its
# result some other way.  Hence the globals rather than an echoed path.
FETCH_DIR=""
FETCH_VER=""

fetch_suckless() {   # <project> <download subdir> <versions...>; sets FETCH_DIR
	proj="$1"; sub="$2"; shift 2
	FETCH_DIR=""; FETCH_VER=""
	for v in "$@"; do
		if ftp -V -o "$SRC_ROOT/$proj-$v.tar.gz" \
			"https://dl.suckless.org/$sub/$proj-$v.tar.gz" >/dev/null 2>&1
		then
			rm -rf "$SRC_ROOT/$proj-$v"
			( cd "$SRC_ROOT" && tar zxf "$proj-$v.tar.gz" ) || continue
			[ -d "$SRC_ROOT/$proj-$v" ] || continue
			FETCH_DIR="$SRC_ROOT/$proj-$v"
			FETCH_VER="$v"
			msg "$proj $v unpacked"
			return 0
		fi
	done
	return 1
}

# Suckless patch filenames carry a date and a version, and the directory
# also holds variants (st-alpha-osc11-... and friends) that are for other
# releases.  Restrict to the plain patch and prefer one naming our version.
fetch_patch() {   # fetch_patch <url-dir> <name-regex> <destination> [version]
	tmp="$SRC_ROOT/.index.$$"
	ftp -V -o "$tmp" "$1" >/dev/null 2>&1 || return 1
	list="$(sed -n "s|.*href=\"\\($2[^\"]*\\.diff\\)\".*|\\1|p" "$tmp" | sort)"
	rm -f "$tmp"
	[ -n "$list" ] || return 1
	file=""
	if [ -n "${4:-}" ]; then
		file="$(printf '%s\n' "$list" | grep -F "$4" | tail -n 1 || true)"
	fi
	[ -n "$file" ] || file="$(printf '%s\n' "$list" | tail -n 1)"
	msg "patch: $file"
	ftp -V -o "$3" "$1$file" >/dev/null 2>&1
}

# Swap one array in a suckless config.h for our own, in place.  Replacing
# rather than deleting-and-reinserting means no dependence on whatever
# happens to follow the array in that particular release.
replace_block() {   # <file> <literal declaration prefix> <block-file>
	awk -v decl="$2" -v blk="$3" '
		index($0, decl) == 1 && !done {
			while ((getline line < blk) > 0) print line
			done = 1
			# guard against a one-line array: do not eat the next one
			if (index($0, "};") == 0) skip = 1
			next
		}
		skip && $0 ~ /^};/ { skip = 0; next }
		skip { next }
		{ print }
	' "$1" >"$1.new" && mv "$1.new" "$1" ||
		warn "could not rewrite $1 (looked for: $2)"
}

if [ "$SKIP_SRC" -eq 0 ]; then
	mkdir -p "$SRC_ROOT"
	PKG_CONFIG_PATH="/usr/X11R6/lib/pkgconfig:/usr/local/lib/pkgconfig"
	export PKG_CONFIG_PATH

	# ---- st -------------------------------------------------------------
	msg "building st from source"
	if fetch_suckless st st 0.9.3 0.9.2 0.9.1 0.9; then
		ST_DIR="$FETCH_DIR"
		if fetch_patch "https://st.suckless.org/patches/alpha/" \
			"st-alpha-[0-9]" "$SRC_ROOT/st-alpha.diff" "$FETCH_VER"
		then
			if ( cd "$ST_DIR" && patch -p1 --forward --silent \
				<"$SRC_ROOT/st-alpha.diff" )
			then
				ST_PATCHED=1
				msg "alpha patch applied: background only, text stays opaque"
			else
				warn "alpha patch did not apply; re-extracting clean source"
				fetch_suckless st st 0.9.3 0.9.2 0.9.1 0.9 || true
				ST_DIR="$FETCH_DIR"
				warn "transparency will come from picom instead (text fades too)"
			fi
		else
			warn "could not fetch the alpha patch; using picom's opacity-rule"
		fi

		render "$ST_DIR/colors.block" 644 <<'STEOF'
static const char *colorname[] = {
	/* 8 normal colours */
	"@C00@", "@C01@", "@C02@", "@C03@",
	"@C04@", "@C05@", "@C06@", "@C07@",

	/* 8 bright colours */
	"@C08@", "@C09@", "@C10@", "@C11@",
	"@C12@", "@C13@", "@C14@", "@C15@",

	[255] = 0,

	/* 256..259: cursor, reverse cursor, foreground, background */
	"@ACCENT@",
	"@BG@",
	"@FG@",
	"@BG@",
};
STEOF
		cp "$ST_DIR/config.def.h" "$ST_DIR/config.h"
		sed -i "s|^static char \\*font = .*|static char *font = \"$FONT_FAMILY:size=$FONT_SIZE:antialias=true:autohint=true\";|" \
			"$ST_DIR/config.h"
		replace_block "$ST_DIR/config.h" \
			'static const char *colorname[]' "$ST_DIR/colors.block"
		# the alpha patch adds this line; a harmless no-op if unpatched
		sed -i "s|^static const float alpha = .*|static const float alpha = $ST_ALPHA;|" \
			"$ST_DIR/config.h"

		# suckless config.mk hardcodes CC = c99; OpenBSD only has cc
		if ( cd "$ST_DIR" && gmake CC=cc PREFIX=/usr/local \
			X11INC=/usr/X11R6/include X11LIB=/usr/X11R6/lib \
			clean install ) >"$SRC_ROOT/st-build.log" 2>&1
		then
			msg "st installed to /usr/local/bin/st"
		else
			warn "st failed to build. Last lines of $SRC_ROOT/st-build.log:"
			tail -n 15 "$SRC_ROOT/st-build.log" >&2
			ST_PATCHED=0
		fi
	else
		warn "could not download st; the terminal will fall back to xterm"
	fi

	# ---- dmenu ----------------------------------------------------------
	msg "building dmenu from source"
	if fetch_suckless dmenu tools 5.3 5.2 5.1 5.0; then
		DM_DIR="$FETCH_DIR"
		if fetch_patch "https://tools.suckless.org/dmenu/patches/center/" \
			"dmenu-center-[0-9]" "$SRC_ROOT/dmenu-center.diff" "$FETCH_VER"
		then
			if ( cd "$DM_DIR" && patch -p1 --forward --silent \
				<"$SRC_ROOT/dmenu-center.diff" )
			then
				msg "center patch applied"
			else
				warn "center patch did not apply; re-extracting clean source"
				fetch_suckless dmenu tools 5.3 5.2 5.1 5.0 || true
				DM_DIR="$FETCH_DIR"
				warn "dmenu will be a top bar rather than centered"
			fi
		else
			warn "could not fetch the center patch; dmenu will be a top bar"
		fi

		render "$DM_DIR/colors.block" 644 <<'DMEOF'
static const char *colors[SchemeLast][2] = {
	/*                 foreground   background */
	[SchemeNorm] = { "@FG@",     "@BG@"     },
	[SchemeSel]  = { "@BG@",     "@ACCENT@" },
	[SchemeOut]  = { "@BG@",     "@HSMAG@"  },
};
DMEOF
		render "$DM_DIR/fonts.block" 644 <<'DMFEOF'
static const char *fonts[] = {
	"@FONT@:size=@FSIZE@"
};
DMFEOF
		cp "$DM_DIR/config.def.h" "$DM_DIR/config.h"
		replace_block "$DM_DIR/config.h" \
			'static const char *fonts[]' "$DM_DIR/fonts.block"
		replace_block "$DM_DIR/config.h" \
			'static const char *colors[SchemeLast][2]' "$DM_DIR/colors.block"
		# the center patch adds these; turning it on avoids needing -c
		sed -i -e "s|^static int centered = .*|static int centered = 1;|" \
			-e "s|^static int min_width = .*|static int min_width = 720;|" \
			"$DM_DIR/config.h"

		if ( cd "$DM_DIR" && gmake CC=cc PREFIX=/usr/local \
			X11INC=/usr/X11R6/include X11LIB=/usr/X11R6/lib \
			clean install ) >"$SRC_ROOT/dmenu-build.log" 2>&1
		then
			msg "dmenu installed to /usr/local/bin/dmenu"
		else
			warn "dmenu failed to build. Last lines of $SRC_ROOT/dmenu-build.log:"
			tail -n 15 "$SRC_ROOT/dmenu-build.log" >&2
		fi
	else
		warn "could not download dmenu; mod-d will not do anything"
	fi
else
	msg "skipping source builds (-N)"
	if [ -x /usr/local/bin/st ]; then ST_PATCHED=1; fi
fi

# ------------------------------------------------------------- login class --

if ! grep -q '^xmonad:' /etc/login.conf; then
	msg "adding an 'xmonad' login class to /etc/login.conf"
	cp -p /etc/login.conf "/etc/login.conf.bak.$STAMP"
	cat >>/etc/login.conf <<'EOF'

# added by openbsd-xmonad-setup.sh -- ghc/cabal need a lot of address space
xmonad:\
	:datasize-cur=4096M:\
	:datasize-max=infinity:\
	:maxproc-cur=1024:\
	:maxproc-max=1024:\
	:openfiles-cur=4096:\
	:openfiles-max=8192:\
	:stacksize-cur=32M:\
	:tc=default:
EOF
	if [ -f /etc/login.conf.db ]; then
		msg "rebuilding /etc/login.conf.db"
		cap_mkdb /etc/login.conf
	fi
fi

CUR_CLASS="$(awk -F: -v u="$TARGET_USER" '$1 == u { print $5 }' /etc/master.passwd)"
if [ "$CUR_CLASS" != "xmonad" ]; then
	msg "moving $TARGET_USER into the 'xmonad' login class (was '${CUR_CLASS:-default}')"
	usermod -L xmonad "$TARGET_USER"
fi

# ----------------------------------------------------------- build sandbox --

msg "creating the build area in $XM_ROOT"
mkdir -p "$XM_ROOT/cabal" "$XM_ROOT/tmp" "$XM_ROOT/dist" "$XM_ROOT/cache"

CFGDIR="$HOMEDIR/.config/xmonad"
mkdir -p "$CFGDIR" "$HOMEDIR/.config/xmobar" "$HOMEDIR/.local/bin" \
	"$HOMEDIR/.local/share/xmonad" "$HOMEDIR/.cache"

for d in "$HOMEDIR/.config" "$HOMEDIR/.local" "$HOMEDIR/.local/share" \
	"$HOMEDIR/.cache"; do
	chown "$TARGET_USER:$TARGET_GROUP" "$d"
done

if [ ! -L "$HOMEDIR/.cache/xmonad" ]; then
	backup "$HOMEDIR/.cache/xmonad"
	ln -s "$XM_ROOT/cache" "$HOMEDIR/.cache/xmonad"
fi

# =========================================================================
# xmonad.hs
# =========================================================================

msg "writing $CFGDIR/xmonad.hs"
backup "$CFGDIR/xmonad.hs"
render "$CFGDIR/xmonad.hs" 644 <<'EOF'
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
--
-- ~/.config/xmonad/xmonad.hs -- generated by openbsd-xmonad-setup.sh
--
-- sway-style bindings, mod is the Super key.  mod-shift-slash lists them.
-- mod-shift-c rebuilds this file and restarts.  Build errors land in an
-- xmessage and in ~/.cache/xmonad/xmonad.errors.
--

import qualified Control.Exception as E
import           Data.List (isSuffixOf)
import qualified Data.Map as M
import           System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import           System.Exit (exitSuccess)
import           System.IO (Handle, hPutStrLn)

import XMonad
import XMonad.Actions.Navigation2D
import XMonad.Actions.Submap (submap)
import XMonad.Hooks.DynamicLog
import XMonad.Hooks.EwmhDesktops (ewmh)
import XMonad.Hooks.ManageDocks (ToggleStruts (..), avoidStruts, docks)
import XMonad.Hooks.ManageHelpers (doCenterFloat, doFullFloat, isDialog, isFullscreen)
import XMonad.Layout.BinarySpacePartition
import XMonad.Layout.IndependentScreens (countScreens)
import XMonad.Layout.MultiToggle
import XMonad.Layout.MultiToggle.Instances (StdTransformers (FULL, MIRROR))
import XMonad.Layout.Spacing (Border (..), spacingRaw)
import XMonad.Layout.Tabbed
import XMonad.Util.Cursor
import XMonad.Util.EZConfig (additionalKeysP, removeKeysP)
import XMonad.Util.NamedScratchpad
import XMonad.Util.Run (runProcessWithInput, spawnPipe)
import XMonad.Util.SpawnOnce (spawnOnce)
import qualified XMonad.StackSet as W

-- theme --------------------------------------------------------------------

colBg, colBgAlt, colFg, colDim, colAccent, colUrgent, colMag, colBorder :: String
colBg     = "@BG@"
colBgAlt  = "@BGALT@"
colFg     = "@FG@"
colDim    = "@DIM@"
colAccent = "@ACCENT@"
colUrgent = "@URGENT@"
colMag    = "@HSMAG@"
colBorder = "@BORDER@"

myFont :: String
myFont = "xft:@FONT@:size=@FSIZE@"

myWorkspaces :: [String]
myWorkspaces = map show [1 .. 9 :: Int]

myTabTheme :: Theme
myTabTheme = def
    { activeColor         = colAccent
    , inactiveColor       = colBgAlt
    , urgentColor         = colUrgent
    , activeBorderColor   = colAccent
    , inactiveBorderColor = colBgAlt
    , urgentBorderColor   = colUrgent
    , activeTextColor     = colBg
    , inactiveTextColor   = colFg
    , urgentTextColor     = colBg
    , fontName            = myFont
    , decoHeight          = @DECOH@
    }

-- A tabbed layout as a MultiToggle transformer, so mod-w flips the whole
-- workspace into tabs the way sway does for a container.
data TABBED = TABBED deriving (Read, Show, Eq)

instance Transformer TABBED Window where
    transform TABBED x k = k (tabbed shrinkText myTabTheme) (const x)

-- main ---------------------------------------------------------------------

main :: IO ()
main = do
    term <- firstOf ["st", "alacritty", "xterm"]
    home <- getHomeDirectory
    -- xmonad re-execs itself on restart but spawnPipe's children survive,
    -- so the old bars have to go before new ones are started.
    ignoring (runProcessWithInput "pkill" ["-x", "xmobar"] "")
    n <- countScreens
    bars <- mapM (startBar (home ++ "/.config/xmobar/xmobarrc")) [0 .. n - 1]
    xmonad
        . ewmh
        . docks
        . withNavigation2DConfig def
        $ def
            { terminal           = term
            , modMask            = mod4Mask
            , workspaces         = myWorkspaces
            , borderWidth        = @BORDERW@
            , normalBorderColor  = colBorder
            , focusedBorderColor = colAccent
            , focusFollowsMouse  = True
            , clickJustFocuses   = False
            , layoutHook         = myLayout
            , manageHook         = myManageHook term
            , startupHook        = myStartupHook
            , logHook            = dynamicLogWithPP (myPP bars)
            }
        `removeKeysP` myRemovedKeys
        `additionalKeysP` myKeys term

-- layouts ------------------------------------------------------------------

-- FULL sits outside avoidStruts so mod-f covers the bars, as sway does.
-- No smartBorders: it strips the border off a lone window, and the point
-- here is that every window is outlined.
myLayout =
    mkToggle (single FULL)
        . avoidStruts
        . mkToggle (single TABBED)
        . mkToggle (single MIRROR)
        $ gaps (emptyBSP ||| Tall 1 (3 / 100) (1 / 2))
  where
    -- outer gap against the screen edge, inner gap around each window
    gaps = spacingRaw False (Border o o o o) True (Border i i i i) True
    o = @GAPOUT@
    i = @GAPIN@

-- window rules -------------------------------------------------------------

myManageHook :: String -> ManageHook
myManageHook term = composeAll
    [ className =? "Xmessage" --> doCenterFloat
    , isDialog                --> doCenterFloat
    , isFullscreen            --> doFullFloat
    ] <+> namedScratchpadManageHook (myScratchpads term)

myScratchpads :: String -> [NamedScratchpad]
myScratchpads term =
    [ NS "term" cmd (className =? "scratchpad" <||> appName =? "scratchpad")
        (customFloating (W.RationalRect 0.15 0.1 0.7 0.6))
    ]
  where
    cmd | "st" `isSuffixOf` term = term ++ " -c scratchpad"
        | otherwise              = term ++ " -name scratchpad"

myStartupHook :: X ()
myStartupHook = do
    setDefaultCursor xC_left_ptr
    spawnOnce "picom -b"
    spawn "$HOME/.local/bin/xmonad-displays"
    spawn "$HOME/.local/bin/xmonad-background"

-- status bars --------------------------------------------------------------

-- One xmobar per physical screen, all fed the same log line.
startBar :: FilePath -> Int -> IO Handle
startBar rc n = do
    mbin <- findExecutable "xmobar"
    haveRc <- doesFileExist rc
    let bin = maybe "xmobar" id mbin
        arg = if haveRc then " " ++ rc else ""
    spawnPipe (bin ++ " -x " ++ show n ++ arg)

myPP :: [Handle] -> PP
myPP hs = xmobarPP
    { ppOutput          = \s -> mapM_ (\h -> safePut h s) hs
    , ppCurrent         = xmobarColor colBg colAccent . pad
    , ppVisible         = xmobarColor colAccent "" . pad
    , ppHidden          = xmobarColor colFg "" . pad
    , ppHiddenNoWindows = xmobarColor colDim "" . pad
    , ppUrgent          = xmobarColor colUrgent "" . pad
    , ppSep             = xmobarColor colDim "" "   "
    , ppWsSep           = ""
    , ppLayout          = xmobarColor colMag ""
    , ppTitle           = xmobarColor colFg "" . shorten 80
      -- keep the scratchpad's hidden workspace out of the bar
    , ppSort            = fmap (. filter ((/= "NSP") . W.tag)) (ppSort xmobarPP)
    }

-- A dead bar must not take xmonad down with it.
safePut :: Handle -> String -> IO ()
safePut h s = ignoring (hPutStrLn h s)

ignoring :: IO a -> IO ()
ignoring a = (a >> return ()) `E.catch` \e ->
    const (return ()) (e :: E.SomeException)

firstOf :: [String] -> IO String
firstOf []       = return "xterm"
firstOf (c : cs) = do
    m <- findExecutable c
    case m of
        Just p  -> return p
        Nothing -> firstOf cs

-- keys ---------------------------------------------------------------------

-- xmonad defaults that sway uses for something else, or not at all.
myRemovedKeys :: [String]
myRemovedKeys =
    [ "M-p", "M-S-p", "M-n", "M-m", "M-t", "M-,", "M-.", "M-q"
    , "M-S-w", "M-S-r"
    ]

myKeys :: String -> [(String, X ())]
myKeys term =
    [ ("M-<Return>",   spawn term)
    , ("M-d",          spawn dmenuCmd)
    , ("M-S-q",        kill)                       -- sway: close window
    , ("M-S-c",        spawn "xmonad --recompile && xmonad --restart")
    , ("M-S-e",        confirmExit)

      -- focus and movement.  Navigation2D crosses monitors, which is how
      -- windows move between outputs here.
    , ("M-h",          windowGo L False)
    , ("M-j",          windowGo D False)
    , ("M-k",          windowGo U False)
    , ("M-l",          windowGo R False)
    , ("M-<Left>",     windowGo L False)
    , ("M-<Down>",     windowGo D False)
    , ("M-<Up>",       windowGo U False)
    , ("M-<Right>",    windowGo R False)
    , ("M-S-h",        windowSwap L False)
    , ("M-S-j",        windowSwap D False)
    , ("M-S-k",        windowSwap U False)
    , ("M-S-l",        windowSwap R False)
    , ("M-S-<Left>",   windowSwap L False)
    , ("M-S-<Down>",   windowSwap D False)
    , ("M-S-<Up>",     windowSwap U False)
    , ("M-S-<Right>",  windowSwap R False)

      -- layout
    , ("M-f",          sendMessage (Toggle FULL))
    , ("M-w",          sendMessage (Toggle TABBED))
    , ("M-s",          sendMessage (Toggle MIRROR))
    , ("M-b",          sendMessage Rotate)
    , ("M-v",          sendMessage Rotate)
    , ("M-e",          sendMessage Swap)
    , ("M-a",          sendMessage FocusParent)
    , ("M-<Space>",    sendMessage NextLayout)
    , ("M-S-<Space>",  withFocused toggleFloat)
    , ("M-r",          resizeMode)

      -- scratchpad
    , ("M--",          namedScratchpadAction (myScratchpads term) "term")
    , ("M-S--",        withFocused (\w -> windows (W.shiftWin "NSP" w)))

      -- extras
    , ("M-S-b",        sendMessage ToggleStruts)
    , ("M-S-w",        spawn "$HOME/.local/bin/xmonad-background")
    , ("M-C-l",        spawn "xlock -mode blank")
    , ("M-S-/",        spawn "xmessage -file $HOME/.config/xmonad/keys.txt")
    ]
  where
    dmenuCmd =
        "dmenu_run -l 12 -p 'run' -fn '@FONT@:size=@FSIZE@'"
            ++ " -nb '" ++ colBg ++ "' -nf '" ++ colFg ++ "'"
            ++ " -sb '" ++ colAccent ++ "' -sf '" ++ colBg ++ "'"

    toggleFloat w = windows $ \s ->
        if M.member w (W.floating s)
            then W.sink w s
            else W.float w (W.RationalRect 0.2 0.2 0.6 0.6) s

    -- mod-shift-e, then y to confirm.  Anything else cancels.
    confirmExit = submap . M.fromList $ [((0, xK_y), io exitSuccess)]

    -- a sticky resize mode: h/j/k/l grow, shift reverses, Escape leaves
    resizeMode = submap . M.fromList $
        [ ((0,         xK_h), sendMessage (ExpandTowards L) >> resizeMode)
        , ((0,         xK_j), sendMessage (ExpandTowards D) >> resizeMode)
        , ((0,         xK_k), sendMessage (ExpandTowards U) >> resizeMode)
        , ((0,         xK_l), sendMessage (ExpandTowards R) >> resizeMode)
        , ((shiftMask, xK_h), sendMessage (ShrinkFrom L) >> resizeMode)
        , ((shiftMask, xK_j), sendMessage (ShrinkFrom D) >> resizeMode)
        , ((shiftMask, xK_k), sendMessage (ShrinkFrom U) >> resizeMode)
        , ((shiftMask, xK_l), sendMessage (ShrinkFrom R) >> resizeMode)
        , ((0,    xK_Escape), return ())
        , ((0,    xK_Return), return ())
        ]
EOF

msg "writing $CFGDIR/xmonad-config.cabal"
backup "$CFGDIR/xmonad-config.cabal"
cat >"$CFGDIR/xmonad-config.cabal" <<'EOF'
cabal-version:      2.4
name:               xmonad-config
version:            0.1
synopsis:           Personal xmonad configuration
build-type:         Simple

executable xmonad-config
    main-is:          xmonad.hs
    build-depends:    base >= 4 && < 5
                    , containers
                    , directory
                    , X11
                    , xmonad >= 0.18 && < 0.20
                    , xmonad-contrib >= 0.18 && < 0.20
    default-language: Haskell2010
EOF

msg "writing $CFGDIR/build"
backup "$CFGDIR/build"
cat >"$CFGDIR/build" <<'EOF'
#!/bin/sh
#
# Custom build script.  "xmonad --recompile" runs this instead of calling
# ghc directly, and passes the path of the binary it wants as $1.
#
set -e

out="$1"
cfg="$(cd "$(dirname "$0")" && pwd)"
root="/usr/local/xmonad/$(id -un)"

# Everything cabal writes and then executes has to be on a wxallowed file
# system, which /home is not.
CABAL_DIR="$root/cabal"; export CABAL_DIR
TMPDIR="$root/tmp";      export TMPDIR
dist="$root/dist"
mkdir -p "$CABAL_DIR" "$TMPDIR" "$dist" "$(dirname "$out")"

# xmonad cannot tell whether a rebuild is needed when a build script is in
# play, so it runs this on every start.  Bail out early if nothing changed.
if [ -x "$out" ] && [ "$out" -nt "$cfg/xmonad.hs" ] &&
	[ "$out" -nt "$cfg/xmonad-config.cabal" ]; then
	exit 0
fi

cd "$cfg"
ulimit -d 4194304 2>/dev/null || true

# X headers and libraries live under /usr/X11R6 here, gmp/libffi/iconv
# under /usr/local.  Add --jobs=1 if the machine runs out of memory.
cabal build \
	--builddir="$dist" \
	--extra-include-dirs=/usr/X11R6/include \
	--extra-lib-dirs=/usr/X11R6/lib \
	--extra-include-dirs=/usr/local/include \
	--extra-lib-dirs=/usr/local/lib

bin="$(cabal list-bin --builddir="$dist" xmonad-config 2>/dev/null || true)"
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
	bin="$(find "$dist" -type f -name xmonad-config -perm -100 | head -n 1)"
fi
[ -n "$bin" ] || { echo "build: cannot find the compiled binary" >&2; exit 1; }

cp -f "$bin" "$out.new"
chmod 755 "$out.new"
mv -f "$out.new" "$out"
EOF
chmod 755 "$CFGDIR/build"

# =========================================================================
# xmobar, picom, background, displays, Xresources
# =========================================================================

msg "writing $HOMEDIR/.config/xmobar/xmobarrc"
backup "$HOMEDIR/.config/xmobar/xmobarrc"
render "$HOMEDIR/.config/xmobar/xmobarrc" 644 <<'EOF'
-- One instance per screen, started by xmonad with -x N.
-- StdinReader is fed by the logHook: workspaces, layout, window title.
Config { font         = "xft:@FONT@:size=@FSIZE@"
       , bgColor      = "@BG@"
       , fgColor      = "@FG@"
       , position     = TopSize L 100 @BARH@
       , lowerOnStart = True
       , hideOnStart  = False
       , persistent   = True
       , sepChar      = "%"
       , alignSep     = "}{"
       , commands     = [ Run StdinReader
                        , Run Date "%a %d %b  %H:%M" "date" 300
                        ]
       , template     = " %StdinReader% }{ <fc=@ACCENT@>%date%</fc> "
       }
EOF

msg "writing $HOMEDIR/.config/picom.conf"
if [ "$ST_PATCHED" -eq 1 ]; then
	render "$HOMEDIR/.config/picom.conf" 644 <<'EOF'
# st is built with the alpha patch, so it handles its own background
# transparency and the text stays fully opaque.  picom only has to be
# running for the 32-bit visual to composite.
backend = "xrender";
vsync = false;
detect-client-opacity = true;
corner-radius = 0;
shadow = false;
fading = false;
EOF
else
	render "$HOMEDIR/.config/picom.conf" 644 <<'EOF'
# The st alpha patch was not applied, so opacity is forced here instead.
# Note this fades the text along with the background.
backend = "xrender";
vsync = false;
detect-client-opacity = true;
corner-radius = 0;
shadow = false;
fading = false;

opacity-rule = [
	"@OPACITY@:class_g = 'st-256color'",
	"@OPACITY@:class_g = 'st'",
	"@OPACITY@:class_g = 'scratchpad'"
];
EOF
fi

msg "writing $CFGDIR/background.conf"
if [ ! -f "$CFGDIR/background.conf" ]; then
	render "$CFGDIR/background.conf" 644 <<'EOF'
# Read by ~/.local/bin/xmonad-background.  mod-shift-w re-applies it.

# Solid colour, used when no image is set or no wallpaper setter is around.
BACKGROUND_COLOR="@BG@"

# Absolute path to an image; leave empty for the solid colour above.
BACKGROUND_IMAGE=""

# zoom | stretch | center | tile | maximize
BACKGROUND_MODE="zoom"
EOF
fi

msg "writing $HOMEDIR/.local/bin/xmonad-background"
cat >"$HOMEDIR/.local/bin/xmonad-background" <<'EOF'
#!/bin/sh
# Apply the desktop background described by ~/.config/xmonad/background.conf.

conf="$HOME/.config/xmonad/background.conf"
[ -r "$conf" ] && . "$conf"

: "${BACKGROUND_COLOR:=#1c1826}"
: "${BACKGROUND_IMAGE:=}"
: "${BACKGROUND_MODE:=zoom}"

if [ -n "$BACKGROUND_IMAGE" ] && [ -r "$BACKGROUND_IMAGE" ]; then
	if command -v xwallpaper >/dev/null 2>&1; then
		case "$BACKGROUND_MODE" in
		tile)     exec xwallpaper --tile "$BACKGROUND_IMAGE" ;;
		center)   exec xwallpaper --center "$BACKGROUND_IMAGE" ;;
		stretch)  exec xwallpaper --stretch "$BACKGROUND_IMAGE" ;;
		maximize) exec xwallpaper --maximize "$BACKGROUND_IMAGE" ;;
		*)        exec xwallpaper --zoom "$BACKGROUND_IMAGE" ;;
		esac
	elif command -v feh >/dev/null 2>&1; then
		case "$BACKGROUND_MODE" in
		tile)     exec feh --bg-tile "$BACKGROUND_IMAGE" ;;
		center)   exec feh --bg-center "$BACKGROUND_IMAGE" ;;
		stretch)  exec feh --bg-scale "$BACKGROUND_IMAGE" ;;
		maximize) exec feh --bg-max "$BACKGROUND_IMAGE" ;;
		*)        exec feh --bg-fill "$BACKGROUND_IMAGE" ;;
		esac
	fi
fi

exec xsetroot -solid "$BACKGROUND_COLOR"
EOF
chmod 755 "$HOMEDIR/.local/bin/xmonad-background"

msg "writing $CFGDIR/displays.conf"
if [ ! -f "$CFGDIR/displays.conf" ]; then
	{
		echo "# Outputs in physical order, left to right, as named by 'xrandr -q'."
		echo "# Applied at session start by ~/.local/bin/xmonad-displays."
		echo "# The same order goes into /etc/X11/xorg.conf.d/10-monitors.conf,"
		echo "# which is what fixes the xenodm greeter as well as the session."
		if [ -n "$OUTPUTS" ]; then
			echo "OUTPUTS=\"$(echo "$OUTPUTS" | tr ',' ' ')\""
		else
			echo "#OUTPUTS=\"DP-1 HDMI-1\""
		fi
	} >"$CFGDIR/displays.conf"
	chmod 644 "$CFGDIR/displays.conf"
fi

msg "writing $HOMEDIR/.local/bin/xmonad-displays"
cat >"$HOMEDIR/.local/bin/xmonad-displays" <<'EOF'
#!/bin/sh
# Lay the monitors out left to right.
#
# The order comes from displays.conf.  If that names an output that is not
# actually connected the name is reported rather than silently ignored --
# a wrong name is why displays end up mirrored at 0x0.  With no order given
# at all, every connected output is extended in the order xrandr lists
# them, which is at worst the right monitors in the wrong order.

conf="$HOME/.config/xmonad/displays.conf"
[ -r "$conf" ] && . "$conf"

connected=$(xrandr -q 2>/dev/null | sed -n 's/^\([^ ][^ ]*\) connected.*/\1/p')
if [ -z "$connected" ]; then
	echo "xmonad-displays: xrandr found no connected outputs" >&2
	exit 1
fi

list=""
if [ -n "${OUTPUTS:-}" ]; then
	for out in $OUTPUTS; do
		if echo "$connected" | grep -qx "$out"; then
			list="$list $out"
		else
			echo "xmonad-displays: no connected output called '$out'" >&2
			echo "xmonad-displays: connected outputs are:" $connected >&2
		fi
	done
fi
[ -n "$list" ] || list=$connected

# Build one invocation so the framebuffer is resized a single time; doing
# it as separate xrandr calls can fail halfway and leave a clone.
args=""
prev=""
for out in $list; do
	if [ -z "$prev" ]; then
		args="--output $out --auto --primary --pos 0x0"
	else
		args="$args --output $out --auto --right-of $prev"
	fi
	prev="$out"
done

xrandr $args || {
	echo "xmonad-displays: xrandr failed: xrandr $args" >&2
	exit 1
}
EOF
chmod 755 "$HOMEDIR/.local/bin/xmonad-displays"

msg "writing $HOMEDIR/.Xresources"
backup "$HOMEDIR/.Xresources"
render "$HOMEDIR/.Xresources" 644 <<'EOF'
! Haskell palette, shared with st, dmenu, xmobar and xmonad.
Xft.antialias:          true
Xft.hinting:            true
Xft.hintstyle:          hintslight
Xft.rgba:               rgb

*background:            @BG@
*foreground:            @FG@
*cursorColor:           @ACCENT@
*color0:  @C00@
*color1:  @C01@
*color2:  @C02@
*color3:  @C03@
*color4:  @C04@
*color5:  @C05@
*color6:  @C06@
*color7:  @C07@
*color8:  @C08@
*color9:  @C09@
*color10: @C10@
*color11: @C11@
*color12: @C12@
*color13: @C13@
*color14: @C14@
*color15: @C15@

! xterm is only the fallback if st failed to build
XTerm*faceName:         @FONT@
XTerm*faceSize:         @FSIZE@
XTerm*saveLines:        8192
XTerm*termName:         xterm-256color
XTerm*metaSendsEscape:  true
XTerm*selectToClipboard: true

Xmessage*background:    @BG@
Xmessage*foreground:    @FG@
Xmessage*faceName:      @FONT@
Xmessage*faceSize:      @FSIZE@
EOF

msg "writing $CFGDIR/keys.txt"
cat >"$CFGDIR/keys.txt" <<'EOF'
xmonad, sway-style bindings          (mod = Super / Windows key)

  mod-Return           terminal (st)
  mod-d                dmenu, centered
  mod-Shift-q          close the focused window
  mod-Shift-e          exit -- then press y to confirm
  mod-Shift-c          rebuild xmonad.hs and restart

  mod-h/j/k/l          focus left/down/up/right, across monitors
  mod-arrows           the same
  mod-Shift-h/j/k/l    move the window in that direction
  mod-1 .. mod-9       go to workspace N
  mod-Shift-1 .. 9     move the window to workspace N

  mod-f                fullscreen, covers the bars
  mod-w                tabbed
  mod-s                stacking (mirrored tiling)
  mod-b / mod-v        flip the split under the focus
  mod-e                swap the two sides of the split
  mod-a                focus the parent container
  mod-r                resize mode: h/j/k/l grow, add Shift to shrink,
                       Escape or Return to leave
  mod-Space            cycle layout
  mod-Shift-Space      float / unfloat the focused window

  mod--                scratchpad terminal
  mod-Shift--          send the focused window to the scratchpad

  mod-Shift-b          hide / show the bars
  mod-Shift-w          re-apply the background
  mod-Ctrl-l           lock the screen
  mod-Shift-/          this list

Where xmonad and sway differ
  sway pre-selects a split direction; xmonad's BSP layout can only flip
  an existing split, so mod-b and mod-v both rotate it.
  mod-w tabs the whole workspace rather than one container.
  There are no containers, so mod-a walks the BSP tree instead.
  Monitors are not bound to keys: mod-h and mod-l cross between them.

Files
  ~/.config/xmonad/xmonad.hs        then mod-Shift-c
  ~/.config/xmonad/background.conf  then mod-Shift-w
  ~/.config/xmonad/displays.conf    monitor order
  ~/.config/xmobar/xmobarrc         status bars
  ~/.config/picom.conf              transparency
EOF

msg "writing $HOMEDIR/.xsession"
backup "$HOMEDIR/.xsession"
cat >"$HOMEDIR/.xsession" <<'EOF'
#!/bin/sh
#
# Run by xenodm(1) after login.  Anything printed here lands in
# ~/.xsession-errors.
#
PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/sbin:$PATH"; export PATH

[ -r "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"

# never blank or power down the displays.  xorg.conf.d/20-noblank.conf
# sets the same thing at server start; this covers anything that turns
# DPMS back on after the fact.
xset s off
xset s noblank
xset -dpms

"$HOME/.local/bin/xmonad-displays"
"$HOME/.local/bin/xmonad-background" &

xm="$(command -v xmonad 2>/dev/null || echo /usr/local/bin/xmonad)"
if "$xm"; then
	exit 0
fi

# xmonad fell over -- leave something usable on screen rather than
# bouncing straight back to the login prompt.
exec xterm -geometry 100x30+40+40
EOF
chmod 755 "$HOMEDIR/.xsession"

chown -R "$TARGET_USER:$TARGET_GROUP" "$XM_ROOT"
chmod 700 "$XM_ROOT"
chown -h "$TARGET_USER:$TARGET_GROUP" \
	"$HOMEDIR/.xsession" "$HOMEDIR/.Xresources" "$HOMEDIR/.cache/xmonad"
chown "$TARGET_USER:$TARGET_GROUP" "$HOMEDIR/.config/picom.conf"
chown -R "$TARGET_USER:$TARGET_GROUP" \
	"$CFGDIR" "$HOMEDIR/.config/xmobar" "$HOMEDIR/.local/bin" \
	"$HOMEDIR/.local/share/xmonad"

# =========================================================================
# Displays.  xorg.conf.d covers the greeter as well as the session, and
# survives a change of display manager.
# =========================================================================

msg "writing /etc/X11/xorg.conf.d/20-noblank.conf"
mkdir -p /etc/X11/xorg.conf.d
backup /etc/X11/xorg.conf.d/20-noblank.conf
cat >/etc/X11/xorg.conf.d/20-noblank.conf <<'EOF'
# generated by openbsd-xmonad-setup.sh
# Zero means never: no screen blanking, no DPMS standby/suspend/off.
# Applies from server start, so it covers the xenodm greeter as well.
Section "ServerFlags"
	Option "BlankTime"   "0"
	Option "StandbyTime" "0"
	Option "SuspendTime" "0"
	Option "OffTime"     "0"
EndSection

Section "Extensions"
	Option "DPMS" "Disable"
EndSection
EOF

# A closing lid is the other way this machine can put itself to sleep.
# The sysctl only exists on hardware that has one.
if sysctl machdep.lidaction >/dev/null 2>&1; then
	msg "disabling lid suspend (machdep.lidaction=0)"
	sysctl machdep.lidaction=0 >/dev/null
	if ! grep -q '^machdep.lidaction' /etc/sysctl.conf 2>/dev/null; then
		echo "machdep.lidaction=0	# openbsd-xmonad-setup.sh" >>/etc/sysctl.conf
	fi
fi

if [ -n "$OUTPUTS" ]; then
	msg "writing /etc/X11/xorg.conf.d/10-monitors.conf"
	mkdir -p /etc/X11/xorg.conf.d
	backup /etc/X11/xorg.conf.d/10-monitors.conf
	{
		echo "# generated by openbsd-xmonad-setup.sh -- physical order, left to right"
		prev=""
		for out in $(echo "$OUTPUTS" | tr ',' ' '); do
			echo ""
			echo "Section \"Monitor\""
			echo "    Identifier \"$out\""
			if [ -z "$prev" ]; then
				echo "    Option \"Primary\" \"true\""
			else
				echo "    Option \"RightOf\" \"$prev\""
			fi
			echo "EndSection"
			prev="$out"
		done
	} >/etc/X11/xorg.conf.d/10-monitors.conf
fi

# =========================================================================
# xenodm, in the same palette as everything else.
#
# Colours only.  A bad font resource here can leave xlogin unable to draw,
# and a login screen that will not come up is a poor trade for nicer type.
# =========================================================================

msg "theming xenodm"
if [ ! -f "/etc/X11/xenodm/Xresources.orig" ]; then
	cp -p /etc/X11/xenodm/Xresources /etc/X11/xenodm/Xresources.orig
fi
if ! grep -q 'openbsd-xmonad-setup' /etc/X11/xenodm/Xresources; then
	render "/tmp/xenodm.$STAMP" 644 <<'EOF'

! ---- openbsd-xmonad-setup: Haskell palette -------------------------------
xlogin*font:                @XFONT@
xlogin*promptFont:          @XFONT@
xlogin*failFont:            @XFONT@
xlogin*greetFont:           @XGREET@
xlogin*background:          @BG@
xlogin*foreground:          @FG@
xlogin*greetColor:          @ACCENT@
xlogin*promptColor:         @HSMAG@
xlogin*failColor:           @URGENT@
xlogin*inpColor:            @BGALT@
xlogin*hiColor:             @HSMID@
xlogin*shdColor:            @BG@
xlogin*Login.frameColor:    @HSDARK@
xlogin*borderWidth:         0
xlogin*frameWidth:          3
xlogin*innerFramesWidth:    1
xlogin*sepWidth:            0
xlogin*logoPadding:         12
xlogin*greeting:            OpenBSD / xmonad
xlogin*namePrompt:          login:\040
xlogin*fail:                no
EOF
	cat "/tmp/xenodm.$STAMP" >>/etc/X11/xenodm/Xresources
	rm -f "/tmp/xenodm.$STAMP"
fi

if [ ! -f "/etc/X11/xenodm/Xsetup_0.orig" ] && [ -f /etc/X11/xenodm/Xsetup_0 ]; then
	cp -p /etc/X11/xenodm/Xsetup_0 /etc/X11/xenodm/Xsetup_0.orig
fi
msg "writing /etc/X11/xenodm/Xsetup_0"
render /etc/X11/xenodm/Xsetup_0 755 <<'EOF'
#!/bin/sh
# generated by openbsd-xmonad-setup.sh -- the original is in Xsetup_0.orig
/usr/X11R6/bin/xsetroot -solid "@BG@"
/usr/X11R6/bin/xsetroot -cursor_name left_ptr
/usr/X11R6/bin/xset s off
/usr/X11R6/bin/xset s noblank
/usr/X11R6/bin/xset -dpms
EOF

# ------------------------------------------------------------------- build --

if [ "$SKIP_PKGS" -eq 0 ]; then
	msg "fetching the Hackage package index"
	su -l "$TARGET_USER" -c \
		"CABAL_DIR='$XM_ROOT/cabal' TMPDIR='$XM_ROOT/tmp' cabal update" ||
		warn "cabal update failed -- is the network up?"

	msg "compiling xmonad.hs -- this pulls xmonad and xmonad-contrib from"
	msg "Hackage and builds them, so expect 15 minutes to an hour"
	if su -l "$TARGET_USER" -c "xmonad --recompile"; then
		msg "xmonad built: $XM_ROOT/cache/xmonad-$ARCH-openbsd"
	else
		warn "the build failed. xmonad will still start with its default"
		warn "configuration (Alt as mod, xterm, no bars) and will show the"
		warn "error in an xmessage. See $XM_ROOT/cache/xmonad.errors, then:"
		warn "  su -l $TARGET_USER -c 'xmonad --recompile'"
	fi
fi

# ------------------------------------------------------------------ xenodm --

msg "enabling xenodm"
rcctl enable xenodm

cat <<EOF

Done.

  Log in as $TARGET_USER and xmonad starts automatically.
  mod is Super.  mod-Return is a terminal, mod-d the launcher,
  mod-Shift-/ lists every binding.  mod-Shift-q closes a window;
  leaving the session is mod-Shift-e followed by y.

  Config      ~/.config/xmonad/xmonad.hs      (mod-Shift-c to rebuild)
  Bars        ~/.config/xmobar/xmobarrc       (one per screen)
  Background  ~/.config/xmonad/background.conf
  Monitors    ~/.config/xmonad/displays.conf  and
              /etc/X11/xorg.conf.d/10-monitors.conf
  Sources     $SRC_ROOT
  Build area  $XM_ROOT

EOF

echo "  What actually got installed:"
for pair in "st:terminal (mod-Return)" "dmenu:launcher" "dmenu_run:launcher script" \
	"xmobar:status bars" "picom:transparency"; do
	b="${pair%%:*}"; what="${pair#*:}"
	if command -v "$b" >/dev/null 2>&1; then
		printf '    ok      %-10s %s\n' "$b" "$what"
	else
		printf '    MISSING %-10s %s\n' "$b" "$what"
	fi
done
if [ "$FONT_FAMILY" = "$FONT_FALLBACK" ]; then
	printf '    MISSING %-10s %s\n' "font" "Code New Roman -- using $FONT_FALLBACK"
else
	printf '    ok      %-10s %s\n' "font" "$FONT_FAMILY"
fi
echo

if [ -z "$OUTPUTS" ]; then
	warn "no monitor order was set. Get the names from 'xrandr -q', then:"
	warn "  doas sh $PROG -u $TARGET_USER -m \"LEFT,RIGHT\" -n -N"
fi

if [ "$START_DM" -eq 1 ]; then
	msg "starting xenodm now"
	rcctl start xenodm
else
	msg "reboot, or run 'rcctl start xenodm' when you are ready"
fi
