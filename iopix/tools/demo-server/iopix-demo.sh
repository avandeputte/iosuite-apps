#!/usr/bin/env bash
# iopix demo server for the App Store review, as one self-contained Proxmox LXC, built (and rebuilt) from scratch.
#
# Run on the Proxmox host as root. The first time, with the Cloudflare tunnel's token:
#   CF_TUNNEL_TOKEN=eyJ... bash iopix-demo.sh
# Any time later, to throw the demo away and build it again from nothing (same container id, same tunnel, same
# passwords, so demo.iopix.net and the sign-in given to App Review keep working):
#   bash iopix-demo.sh --rebuild
# Add --new-passwords for fresh passwords, --yes to skip the question before the old container is deleted.
#
# The library: by default about 48 Unsplash sample photos. With DEMO_LIBRARY it is the documentation's demo
# library instead (the photos and the digiKam database behind iopix.net's screenshots, with its named people and
# faces). Make the archive on the Mac and copy it to the Proxmox host once:
#   tar --exclude .DS_Store -czf iopix-demo-library.tgz -C ~/iopix-demo photos db CREDITS.md
#   scp iopix-demo-library.tgz root@<proxmox>:/root/
#   DEMO_LIBRARY=/root/iopix-demo-library.tgz CF_TUNNEL_TOKEN=eyJ... bash iopix-demo.sh
# The archive's path is remembered like the token, so --rebuild uses it again.
#
# It creates an unprivileged Debian 13 container, installs iopix inside it without digiKam (iopix keeps the
# library itself), fills it with freely licensed sample photos (Unsplash, via picsum.photos) given dates and
# places, creates two accounts with passwords (no passwordless account), makes visitors sign in before seeing
# anything, and connects it to Cloudflare with the tunnel token, so it answers at the public hostname set on
# that tunnel (demo.iopix.net) with no Cloudflare Access in front.
#
# Nothing on the host is shared with the container: no bind mounts, its own disk, its own data. The only thing
# kept on the host is /root/iopix-demo.conf (root only): the container id, the tunnel token and the passwords.
#
# Settings (environment, all optional; they win over what /root/iopix-demo.conf remembers):
#   CF_TUNNEL_TOKEN   the token of a Cloudflare tunnel (Zero Trust › Networks › Tunnels); without it the demo
#                     runs on the local network only
#   CTID              container id (default: the remembered one, else the next free one)
#   CT_STORAGE        storage for the container's disk (default: local-lvm)
#   CT_BRIDGE         network bridge (default: vmbr0)
#   CT_HOSTNAME       (default: iopix-demo)
#   PHOTO_COUNT       how many sample photos when there is no DEMO_LIBRARY (default: 48)
#   DEMO_LIBRARY      an archive with photos/ and db/digikam4.db (see above)
set -euo pipefail

REBUILD=0; NEWPW=0; YES=0
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1;; --new-passwords) NEWPW=1;; --yes|-y) YES=1;;
    -h|--help) sed -n '2,27p' "$0"; exit 0;;
    *) echo "Unknown option: $a (try --help)" >&2; exit 1;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
command -v pct >/dev/null || die "Run this on the Proxmox host (pct not found)."
[ "$(id -u)" = 0 ] || die "Run as root."

# what earlier runs remember; the environment wins over it
CONF=/root/iopix-demo.conf
ENV_CTID="${CTID:-}"; ENV_TOKEN="${CF_TUNNEL_TOKEN:-}"; ENV_LIB="${DEMO_LIBRARY:-}"
SAVED_CTID=""; SAVED_TOKEN=""; SAVED_LIBRARY=""; ADMIN_PW=""; REVIEW_PW=""
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
CTID="${ENV_CTID:-$SAVED_CTID}"
CF_TUNNEL_TOKEN="${ENV_TOKEN:-$SAVED_TOKEN}"
DEMO_LIBRARY="${ENV_LIB:-$SAVED_LIBRARY}"
if [ -n "$DEMO_LIBRARY" ]; then
  [ -f "$DEMO_LIBRARY" ] || die "DEMO_LIBRARY: no archive at $DEMO_LIBRARY"
  tar -tzf "$DEMO_LIBRARY" | grep -q '^db/digikam4.db$' || die "DEMO_LIBRARY: the archive has no db/digikam4.db"
fi
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_HOSTNAME="${CT_HOSTNAME:-iopix-demo}"
PHOTO_COUNT="${PHOTO_COUNT:-48}"

# passwords: made once, then kept, so a rebuild does not break the sign-in given to Apple
# (tr stops with SIGPIPE once head has its 16 characters: not a failure, so pipefail must not see it)
gen() { (set +o pipefail; LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom 2>/dev/null | head -c 16); }
if [ "$NEWPW" = 1 ] || [ -z "$ADMIN_PW" ]; then ADMIN_PW="$(gen)"; fi
if [ "$NEWPW" = 1 ] || [ -z "$REVIEW_PW" ]; then REVIEW_PW="$(gen)"; fi

# the old demo goes first; only a container this script made (tagged iopix-demo) is ever deleted
if [ -n "$CTID" ] && pct status "$CTID" >/dev/null 2>&1; then
  pct config "$CTID" | grep -Eq '^tags:.*iopix-demo' || die "Container $CTID exists and is not the iopix demo; set CTID to another id."
  [ "$REBUILD" = 1 ] || die "The demo already exists as container $CTID. Run with --rebuild to replace it with a fresh one."
  if [ "$YES" != 1 ]; then
    read -r -p "Delete container $CTID and build the demo again from scratch? [y/N] " ok
    case "$ok" in y|Y) ;; *) die "Nothing changed.";; esac
  fi
  say "Removing the old demo (container $CTID)"
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" --purge 1
fi
[ -n "$CTID" ] || CTID="$(pvesh get /cluster/nextid)"

( umask 077
  { echo "# kept by iopix-demo.sh: the demo's container, Cloudflare tunnel token and passwords (root only)"
    printf 'SAVED_CTID=%q\nSAVED_TOKEN=%q\nSAVED_LIBRARY=%q\nADMIN_PW=%q\nREVIEW_PW=%q\n' "$CTID" "$CF_TUNNEL_TOKEN" "$DEMO_LIBRARY" "$ADMIN_PW" "$REVIEW_PW"
  } > "$CONF" )
chmod 600 "$CONF"

say "Debian 13 template"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard_.*amd64' | sort -V | tail -1)"
[ -n "$TEMPLATE" ] || die "No Debian 13 template offered by pveam."
TSTORE="local"
pveam list "$TSTORE" | grep -q "$TEMPLATE" || pveam download "$TSTORE" "$TEMPLATE"

say "Container $CTID ($CT_HOSTNAME)"
pct create "$CTID" "$TSTORE:vztmpl/$TEMPLATE" \
  --hostname "$CT_HOSTNAME" --unprivileged 1 --features nesting=1 \
  --cores 2 --memory 2048 --swap 512 --rootfs "$CT_STORAGE:$([ -n "$DEMO_LIBRARY" ] && echo 24 || echo 12)" \
  --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp" --onboot 1 \
  --tags iopix-demo --description "iopix demo for the App Store review (sample photos only)"
pct start "$CTID"
for _ in $(seq 1 30); do pct exec "$CTID" -- sh -c 'getent hosts deb.debian.org >/dev/null' && break; sleep 2; done

say "Installing iopix and the demo library inside the container"
SECF="$(mktemp)"; chmod 600 "$SECF"
printf 'ADMIN_PW=%q\nREVIEW_PW=%q\nCF_TUNNEL_TOKEN=%q\nPHOTO_COUNT=%q\n' "$ADMIN_PW" "$REVIEW_PW" "$CF_TUNNEL_TOKEN" "$PHOTO_COUNT" > "$SECF"
pct push "$CTID" "$SECF" /root/demo.env --perms 0600
rm -f "$SECF"
if [ -n "$DEMO_LIBRARY" ]; then
  say "Copying the demo library into the container"
  pct push "$CTID" "$DEMO_LIBRARY" /root/library.tgz
fi
INSIDE="$(mktemp)"
sed -n '/^# ---- INSIDE ----$/,$p' "$0" | tail -n +2 > "$INSIDE"
pct push "$CTID" "$INSIDE" /root/demo-inside.sh --perms 0700
rm -f "$INSIDE"
pct exec "$CTID" -- bash -c 'set -a; . /root/demo.env; set +a; rm -f /root/demo.env; bash /root/demo-inside.sh' \
  || die "Setup inside the container failed; its log is at /root/demo-setup.log in CT $CTID (pct exec $CTID -- tail -50 /root/demo-setup.log)."

IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
say "Done"
cat <<EOF
Demo iopix: http://$IP:8600 on your network$( [ -n "$CF_TUNNEL_TOKEN" ] && echo ", and at the tunnel's public hostname (demo.iopix.net)" )

Accounts (also in $CONF on this host, and /root/demo-accounts.txt in the container):
  appreview   $REVIEW_PW   editor: for Apple's reviewer
  admin       $ADMIN_PW   admin: for you

Visitors see only the sign-in screen until they sign in.
To start again from scratch at any time:  bash $0 --rebuild
EOF
[ -n "$CF_TUNNEL_TOKEN" ] || cat <<EOF

No tunnel yet. Once you have the token, rebuild with it (it is remembered from then on):
  CF_TUNNEL_TOKEN=<TOKEN> bash $0 --rebuild
EOF
exit 0

# ---- INSIDE ----
# Runs inside the container as root, with ADMIN_PW, REVIEW_PW, CF_TUNNEL_TOKEN and PHOTO_COUNT in the environment.
set -euo pipefail
exec > >(tee -a /root/demo-setup.log) 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "== packages"
apt-get update -q
apt-get install -y -q git python3 python3-venv python3-pip ffmpeg libimage-exiftool-perl libjpeg-turbo-progs \
  libheif1 libglib2.0-0 curl ca-certificates

echo "== iopix"
mkdir -p /opt/iopix /library/photos
[ -d /opt/iopix/app ] || git clone --depth 1 https://github.com/avandeputte/iopix /opt/iopix/app
git -C /opt/iopix/app rev-parse HEAD > /opt/iopix/app/COMMIT 2>/dev/null || true

if [ -f /root/library.tgz ]; then
  echo "== the demo library (photos and digiKam database, with its people and faces)"
  mkdir -p /library
  tar -xzf /root/library.tgz -C /library
  rm -f /root/library.tgz
  echo "  $(find /library/photos -type f ! -name '*.xmp' | wc -l) files"
  DBARG="--sqlite /library/db"
else
DBARG="--no-digikam"
echo "== sample photos (Unsplash, free to use, via picsum.photos)"
# dates spread over the years, and well-known places, so Explore, Places and the map have something to show
PLACES=("48.8584 2.2945 Paris" "40.7580 -73.9855 New York" "35.6595 139.7005 Tokyo" "51.5007 -0.1246 London"
        "41.8902 12.4922 Rome" "-33.8568 151.2153 Sydney" "37.8199 -122.4783 San Francisco" "40.4406 -79.9959 Pittsburgh"
        "64.1466 -21.9426 Reykjavik" "-22.9519 -43.2105 Rio de Janeiro" "52.3676 4.9041 Amsterdam" "50.8467 4.3525 Brussels")
cd /library/photos
n=0; id=10
while [ "$n" -lt "$PHOTO_COUNT" ] && [ "$id" -lt 400 ]; do
  id=$((id + 7))
  f="sample-$(printf '%03d' "$id").jpg"
  [ -s "$f" ] || curl -fsSL --retry 2 -o "$f" "https://picsum.photos/id/$id/2400/1600.jpg" || { rm -f "$f"; continue; }
  year=$((2008 + n % 17)); month=$((1 + (n * 5) % 12)); day=$((1 + (n * 11) % 27))
  # a few photos taken on today's month and day in earlier years, for On this day
  if [ $((n % 9)) = 0 ]; then month=$((10#$(date +%m))); day=$((10#$(date +%d))); fi
  when="$(printf '%04d:%02d:%02d %02d:%02d:00' "$year" "$month" "$day" $((9 + n % 9)) $(((n * 13) % 60)))"
  p=(${PLACES[$((n % ${#PLACES[@]}))]})
  lat="${p[0]}"; lon="${p[1]}"
  exiftool -q -overwrite_original "-DateTimeOriginal=$when" "-CreateDate=$when" \
    "-GPSLatitude=${lat#-}" "-GPSLatitudeRef=$([ "${lat#-}" = "$lat" ] && echo N || echo S)" \
    "-GPSLongitude=${lon#-}" "-GPSLongitudeRef=$([ "${lon#-}" = "$lon" ] && echo E || echo W)" "$f" || true
  y="$year"; mkdir -p "$y"; mv "$f" "$y/"
  n=$((n + 1))
done
echo "  $n photos"
fi

echo "== iopix setup ($DBARG, offline place names, service on port 8600)"
cd /opt/iopix/app
IOPIX_ADMIN="admin:$ADMIN_PW" sh ./setup.sh --yes --photos /library/photos $DBARG --data /opt/iopix/data \
  --features places --service --no-system-deps --port 8600
# no digiKam runs in here to wait for before writing its database
grep -q '^DIGIKAM_CHECK=' /opt/iopix/app/iopix.env || echo DIGIKAM_CHECK=none >> /opt/iopix/app/iopix.env

echo "== accounts and sign-in"
VPY=/opt/iopix/app/.venv/bin/python
cd /opt/iopix/app
# the service's own settings, so this talks to the same database
( set -a; . /opt/iopix/app/iopix.env; set +a; REVIEW_PW="$REVIEW_PW" "$VPY" - ) <<'PY'
import os
from app.data import state
from app import users
state.init(); users.init()
try:
    users.create("appreview", os.environ["REVIEW_PW"], "editor")
    print("  created appreview (editor)")
except ValueError as e:
    print("  appreview:", e)
state.set_setting("require_login", "1")  # visitors see the sign-in screen and nothing else
state.set_setting("app_name", "iopix demo")
print("  sign-in required")
PY
systemctl restart iopix
printf 'appreview  %s  editor (App Store review)\nadmin      %s  admin\n' "$REVIEW_PW" "$ADMIN_PW" > /root/demo-accounts.txt
chmod 600 /root/demo-accounts.txt

if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  echo "== Cloudflare tunnel"
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -q && apt-get install -y -q cloudflared
  cloudflared service install "$CF_TUNNEL_TOKEN"
fi

for _ in $(seq 1 60); do curl -fsS -o /dev/null http://127.0.0.1:8600/api/status && break; sleep 2; done
curl -fsS http://127.0.0.1:8600/api/status >/dev/null && echo "== iopix answers on port 8600"
rm -f /root/demo-inside.sh
