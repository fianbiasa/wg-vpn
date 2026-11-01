#!/bin/bash
# =============================================================================
#  WireGuard Auto Setup — Ubuntu 20.04+ / Debian 11+ (VPS KVM)
#
#  Memasang WireGuard + NAT IPv4/IPv6, firewall nftables, pindah port SSH,
#  tuning (BBR, buffer UDP, MSS clamping), tool manajemen klien `wg-client`,
#  lalu menampilkan config + QR code klien pertama.
#
#  Pemakaian (sebagai root):
#    bash <(curl -fsSL https://raw.githubusercontent.com/fianbiasa/wg-vpn/main/wg-setup.sh) [opsi]
#  Lihat semua opsi: tambahkan --help
# =============================================================================

set -euo pipefail

WG_IFACE=wg0
NET4=10.66.66
NET6_PREFIX=fd42:42:42::
WG_PORT=51820
SSH_PORT=2269
SSH_PORT_EXPLICIT=0
CLIENT_NAME=client1
ENDPOINT=""
CLIENT_DNS=""
FIREWALL=1
FW=""
FWD_ZONE=""
LOG=/var/log/wg-setup.log
WARNINGS=()

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}✔${N} $*"; }
warn() { echo "    ${Y}!${N} $*"; WARNINGS+=("$*"); }
die()  { echo "${R}Error:${N} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Pemakaian: bash wg-setup.sh [opsi]

  --ssh-port N       Pindahkan SSH ke port N (default: $SSH_PORT, hanya jika SSH
                     masih di port 22; port custom yang sudah ada tidak diubah)
  --keep-ssh-port    Jangan ubah port SSH
  --wg-port N        Port UDP WireGuard (default: $WG_PORT)
  --endpoint HOST    Hostname/IP server untuk config klien (default: otomatis)
  --client NAMA      Nama klien pertama (default: $CLIENT_NAME)
  --dns "A, B"       DNS untuk klien (default: Cloudflare 1.1.1.1)
  --no-firewall      Jangan menyentuh firewall sama sekali
  -h, --help         Tampilkan bantuan ini

Firewall: jika UFW atau firewalld aktif, aturan WireGuard ditambahkan ke sana
(aturan lain tidak diubah). Jika tidak ada firewall aktif, dipasang nftables.
EOF
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --ssh-port|--wg-port|--endpoint|--client|--dns)
        [ $# -ge 2 ] || die "$1 membutuhkan nilai" ;;
    esac
    case $1 in
      --ssh-port)      SSH_PORT=$2; SSH_PORT_EXPLICIT=1; shift 2 ;;
      --keep-ssh-port) SSH_PORT=""; shift ;;
      --wg-port)       WG_PORT=$2; shift 2 ;;
      --endpoint)      ENDPOINT=$2; shift 2 ;;
      --client)        CLIENT_NAME=$2; shift 2 ;;
      --dns)           CLIENT_DNS=$2; shift 2 ;;
      --no-firewall)   FIREWALL=0; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "opsi tidak dikenal: $1 (lihat --help)" ;;
    esac
  done
  valid_port "$WG_PORT" || die "--wg-port tidak valid: $WG_PORT"
  if [ -n "$SSH_PORT" ]; then valid_port "$SSH_PORT" || die "--ssh-port tidak valid: $SSH_PORT"; fi
  [[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "--client hanya boleh huruf, angka, - dan _ (maks 32)"
}

preflight() {
  step "Memeriksa sistem"
  [ "$(id -u)" = 0 ] || die "jalankan sebagai root (sudo -i)"
  : > "$LOG"
  [ -r /etc/os-release ] || die "/etc/os-release tidak ditemukan"
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*|*" debian "*) ;;
    *) die "hanya mendukung Ubuntu/Debian (terdeteksi: ${PRETTY_NAME:-tidak diketahui})" ;;
  esac
  command -v systemctl >/dev/null || die "systemd diperlukan"
  if [ -f /etc/wireguard/$WG_IFACE.conf ]; then
    echo "WireGuard sudah terpasang di server ini (/etc/wireguard/$WG_IFACE.conf)."
    echo "Untuk menambah klien: wg-client add <nama>   |   daftar klien: wg-client list"
    exit 0
  fi
  ok "${PRETTY_NAME}, kernel $(uname -r), virtualisasi: $(systemd-detect-virt 2>/dev/null || echo tidak-diketahui)"
}

install_packages() {
  step "Memasang paket"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local apt=(apt-get -y -q -o DPkg::Lock::Timeout=600)
  "${apt[@]}" update >>"$LOG" 2>&1 || die "apt-get update gagal (lihat $LOG)"
  "${apt[@]}" install --no-install-recommends wireguard-tools qrencode nftables netbase curl iproute2 iputils-ping >>"$LOG" 2>&1 \
    || die "pemasangan paket gagal (lihat $LOG)"
  ok "wireguard-tools, qrencode, nftables, curl"

  modprobe wireguard 2>/dev/null || true
  ip link add wgprobe0 type wireguard 2>/dev/null \
    || die "kernel tidak mendukung WireGuard (VPS OpenVZ/LXC?). Gunakan VPS KVM."
  ip link del wgprobe0
  ok "modul kernel WireGuard tersedia"
}

detect_network() {
  step "Mendeteksi jaringan"
  NIC=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$NIC" ] || die "default route IPv4 tidak ditemukan"
  LOCAL4=$(ip -4 -o addr show dev "$NIC" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
  [ -n "$LOCAL4" ] || die "alamat IPv4 di $NIC tidak ditemukan"

  PUB4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)
  [[ "$PUB4" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || PUB4=$LOCAL4
  ok "interface $NIC, IPv4 publik $PUB4"

  local addrs routes
  HAS_V6=0
  addrs=$(ip -6 -o addr show dev "$NIC" scope global 2>/dev/null || true)
  routes=$(ip -6 route show default 2>/dev/null || true)
  if [ -n "$addrs" ] && [ -n "$routes" ] && curl -6 -fsS --max-time 6 https://api64.ipify.org >/dev/null 2>&1; then
    HAS_V6=1; NET6=$NET6_PREFIX; ok "IPv6 aktif — klien mendapat IPv4 + IPv6"
  else
    NET6=""; ok "IPv6 tidak tersedia — tunnel IPv4 saja"
  fi

  if ip -4 -o addr | grep -qF " $NET4."; then die "subnet $NET4.0/24 sudah dipakai di server ini"; fi
  if [ -n "$(ss -lunH "sport = :$WG_PORT" 2>/dev/null)" ]; then die "port UDP $WG_PORT sudah dipakai"; fi

  local nic_mtu; nic_mtu=$(cat /sys/class/net/"$NIC"/mtu)
  WG_MTU=$((nic_mtu - 80))
  if [ $WG_MTU -gt 1420 ]; then WG_MTU=1420; fi
  if [ $WG_MTU -lt 1280 ]; then WG_MTU=1280; fi
  ok "MTU $NIC $nic_mtu → MTU WireGuard $WG_MTU"

  if [ -z "$ENDPOINT" ]; then
    local fqdn doh=""
    fqdn=$(hostname -f 2>/dev/null || hostname)
    if [[ "$fqdn" == *.* ]]; then
      doh=$(curl -fsS --max-time 6 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$fqdn&type=A" 2>/dev/null || true)
    fi
    if [[ "$doh" == *"\"data\":\"$PUB4\""* ]]; then
      ENDPOINT=$fqdn; ok "endpoint klien: $fqdn (DNS cocok dengan $PUB4)"
    else
      ENDPOINT=$PUB4; ok "endpoint klien: $PUB4 (hostname '$fqdn' tidak mengarah ke IP ini)"
    fi
  else
    ok "endpoint klien: $ENDPOINT"
  fi

  if [ -z "$CLIENT_DNS" ]; then
    CLIENT_DNS="1.1.1.1, 1.0.0.1"
    if [ $HAS_V6 = 1 ]; then CLIENT_DNS+=", 2606:4700:4700::1111, 2606:4700:4700::1001"; fi
  fi

  local drv=""
  if [ -e /sys/class/net/"$NIC"/device/driver ]; then
    drv=$(basename "$(readlink /sys/class/net/"$NIC"/device/driver)")
  fi
  case $drv in
    8139cp|8139too|ne2k-pci|pcnet32|e1000|e1000e)
      warn "NIC VPS memakai driver emulasi '$drv' (lambat, rawan drop paket saat trafik tinggi). Minta provider mengganti model NIC ke virtio." ;;
  esac
}

detect_firewall() {
  step "Mendeteksi firewall"
  local ufw_status=""
  if command -v ufw >/dev/null; then ufw_status=$(ufw status 2>/dev/null || true); fi

  if [ $FIREWALL = 0 ]; then
    FW=none; ok "dilewati (--no-firewall)"
  elif [[ "$ufw_status" == *"Status: active"* ]]; then
    FW=ufw; ok "UFW aktif — aturan WireGuard akan ditambahkan ke UFW"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    FW=firewalld
    FWD_ZONE=$(firewall-cmd --get-zone-of-interface="$NIC" 2>/dev/null || firewall-cmd --get-default-zone)
    ok "firewalld aktif (zona $FWD_ZONE) — aturan WireGuard akan ditambahkan ke firewalld"
  else
    FW=nftables; ok "tidak ada firewall aktif — akan dipasang firewall nftables"
  fi
}

# Buka port TCP di firewall yang sudah aktif, sebelum SSH dipindah ke port itu
fw_open_tcp() {
  case $FW in
    ufw)       ufw allow "$1/tcp" comment 'SSH' >>"$LOG" 2>&1 ;;
    firewalld) firewall-cmd -q --permanent --zone="$FWD_ZONE" --add-port="$1/tcp" >>"$LOG" 2>&1 \
                 && firewall-cmd -q --zone="$FWD_ZONE" --add-port="$1/tcp" >>"$LOG" 2>&1 ;;
    *)         return 0 ;;
  esac
}

setup_sysctl() {
  step "Mengatur kernel (forwarding, BBR, buffer)"
  local bbr=0
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then bbr=1; fi
  {
    echo "# WireGuard VPN (dibuat oleh wg-setup)"
    echo "net.ipv4.ip_forward = 1"
    if [ $HAS_V6 = 1 ]; then
      echo "net.ipv6.conf.all.forwarding = 1"
      echo "net.ipv6.conf.default.forwarding = 1"
      echo "# tetap terima Router Advertisement walau forwarding aktif"
      echo "net.ipv6.conf.${NIC//./\/}.accept_ra = 2"
    fi
    if [ $bbr = 1 ]; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
    echo "net.core.rmem_max = 16777216"
    echo "net.core.wmem_max = 16777216"
  } > /etc/sysctl.d/99-wireguard.conf
  if [ $bbr = 1 ]; then echo tcp_bbr > /etc/modules-load.d/bbr.conf; fi
  if sysctl -q -p /etc/sysctl.d/99-wireguard.conf >>"$LOG" 2>&1; then
    ok "forwarding aktif$([ $bbr = 1 ] && echo ', BBR + fq aktif')"
  else
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then die "gagal mengaktifkan IP forwarding (lihat $LOG)"; fi
    warn "sebagian sysctl tidak bisa diterapkan (lihat $LOG)"
  fi
  if [ $HAS_V6 = 1 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" != 1 ]; then
    warn "IPv6 forwarding gagal diaktifkan — klien tidak akan mendapat IPv6"
  fi
}

write_wireguard() {
  step "Mengonfigurasi WireGuard"
  umask 077
  mkdir -p /etc/wireguard/clients
  wg genkey > /etc/wireguard/server.key
  wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub

  cat > /etc/wireguard/params <<EOF
SERVER_ENDPOINT="$ENDPOINT"
SERVER_PORT="$WG_PORT"
SERVER_NIC="$NIC"
WG_IFACE="$WG_IFACE"
NET4="$NET4"
NET6="$NET6"
CLIENT_DNS="$CLIENT_DNS"
CLIENT_MTU="$WG_MTU"
EOF

  local addr="$NET4.1/24"
  if [ -n "$NET6" ]; then addr+=", ${NET6}1/64"; fi
  cat > /etc/wireguard/$WG_IFACE.conf <<EOF
[Interface]
Address = $addr
ListenPort = $WG_PORT
PrivateKey = $(cat /etc/wireguard/server.key)
MTU = $WG_MTU
PostUp = /etc/wireguard/fw.sh up
PostDown = /etc/wireguard/fw.sh down
EOF

  cat > /etc/wireguard/fw.sh <<'FWSH'
#!/bin/bash
# NAT + MSS clamping WireGuard di tabel nftables sendiri (dipanggil wg-quick PostUp/PostDown).
# Tabel terpisah ini tidak ikut terhapus saat UFW/firewalld di-reload.
. /etc/wireguard/params
if [ "$1" = down ]; then nft delete table inet wireguard 2>/dev/null; exit 0; fi
nft -f - <<EOF
table inet wireguard
delete table inet wireguard
table inet wireguard {
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		oifname "$SERVER_NIC" ip saddr $NET4.0/24 masquerade
		$([ -n "$NET6" ] && echo "oifname \"$SERVER_NIC\" ip6 saddr ${NET6}/64 masquerade")
	}
	chain forward {
		type filter hook forward priority -150; policy accept;
		iifname "$WG_IFACE" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
		oifname "$WG_IFACE" tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
	}
}
EOF
FWSH
  chmod 700 /etc/wireguard/fw.sh

  install_wg_client

  systemctl enable --now wg-quick@$WG_IFACE >>"$LOG" 2>&1 \
    || die "wg-quick@$WG_IFACE gagal dijalankan (cek: journalctl -u wg-quick@$WG_IFACE)"
  ok "wg-quick@$WG_IFACE aktif, port UDP $WG_PORT, subnet $NET4.0/24${NET6:+ + ${NET6}/64}"
}

install_wg_client() {
  cat > /usr/local/bin/wg-client <<'WGCLIENT'
#!/bin/bash
# Manajemen klien WireGuard: add | remove | list | show
set -euo pipefail
umask 077

. /etc/wireguard/params
CONF=/etc/wireguard/$WG_IFACE.conf
CDIR=/etc/wireguard/clients

die() { echo "Error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "jalankan sebagai root"

usage() {
  cat <<EOF
Penggunaan: wg-client <perintah> [nama]
  add <nama>      Tambah klien baru (menampilkan QR code)
  remove <nama>   Hapus klien
  list            Daftar klien beserta status koneksi
  show <nama>     Tampilkan config + QR code klien
EOF
  exit 1
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "nama hanya boleh huruf, angka, - dan _ (maks 32 karakter)"; }
exists() { grep -qx "### Client $1" "$CONF"; }

apply() {
  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
  fi
}

show_client() {
  local f=$CDIR/$1.conf
  [ -f "$f" ] || die "klien '$1' tidak ditemukan"
  echo "===== $f ====="
  cat "$f"
  echo
  qrencode -t ansiutf8 < "$f"
}

cmd_add() {
  local name=$1 octet="" i
  valid_name "$name"
  exists "$name" && die "klien '$name' sudah ada"

  for i in $(seq 2 254); do
    grep -q "AllowedIPs = $NET4.$i/32" "$CONF" || { octet=$i; break; }
  done
  [ -n "$octet" ] || die "subnet $NET4.0/24 penuh"

  local priv pub psk spub ips ep
  priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey); psk=$(wg genpsk)
  spub=$(cat /etc/wireguard/server.pub)
  ips="$NET4.$octet/32"
  if [ -n "$NET6" ]; then ips+=", $NET6$octet/128"; fi
  ep=$SERVER_ENDPOINT
  if [[ "$ep" == *:* ]]; then ep="[$ep]"; fi

  cat >> "$CONF" <<EOF

### Client $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ips
EOF

  cat > "$CDIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ips
DNS = $CLIENT_DNS
MTU = $CLIENT_MTU

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $ep:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  apply
  show_client "$name"
  echo "Klien '$name' ditambahkan ($ips)."
}

cmd_remove() {
  local name=$1
  valid_name "$name"
  exists "$name" || die "klien '$name' tidak ditemukan"
  local tmp; tmp=$(mktemp)
  awk -v n="### Client $name" '
    $0 == n { skip = 1; next }
    /^### Client / { skip = 0 }
    !skip { print }
  ' "$CONF" | cat -s > "$tmp"
  cat "$tmp" > "$CONF"; rm -f "$tmp"
  rm -f "$CDIR/$name.conf"
  apply
  echo "Klien '$name' dihapus."
}

cmd_list() {
  local now name pub ip hs ago rx tx
  now=$(date +%s)
  printf '%-20s %-14s %-22s %s\n' NAMA IP "HANDSHAKE TERAKHIR" "RX / TX"
  while read -r name; do
    pub=$(awk -v n="### Client $name" '$0==n{f=1;next} f&&/^PublicKey/{print $3; exit}' "$CONF")
    ip=$(awk -v n="### Client $name" '$0==n{f=1;next} f&&/^AllowedIPs/{sub(",","",$3); print $3; exit}' "$CONF")
    hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p{print $2}')
    if [ -z "$hs" ] || [ "$hs" = 0 ]; then ago="belum pernah"
    else ago="$(( (now - hs) ))s lalu"; fi
    read -r rx tx < <(wg show "$WG_IFACE" transfer 2>/dev/null | awk -v p="$pub" '$1==p{print $2, $3}') || true
    printf '%-20s %-14s %-22s %s / %s\n' "$name" "${ip%/32}" "$ago" \
      "$(numfmt --to=iec "${rx:-0}")" "$(numfmt --to=iec "${tx:-0}")"
  done < <(sed -n 's/^### Client //p' "$CONF")
}

case "${1:-}" in
  add)    [ $# -eq 2 ] || usage; cmd_add "$2" ;;
  remove) [ $# -eq 2 ] || usage; cmd_remove "$2" ;;
  list)   cmd_list ;;
  show)   [ $# -eq 2 ] || usage; show_client "$2" ;;
  *)      usage ;;
esac
WGCLIENT
  chmod 700 /usr/local/bin/wg-client
}

restart_ssh() {
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  else
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
  fi
}

ssh_listening() { [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]; }

setup_ssh() {
  step "Mengatur port SSH"
  if ! command -v sshd >/dev/null; then
    SSH_PORTS=""; warn "openssh-server tidak ditemukan — port SSH tidak diubah"; return 0
  fi
  mkdir -p /run/sshd
  SSH_PORTS=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -un | xargs)
  [ -n "$SSH_PORTS" ] || SSH_PORTS=22

  if [ -z "$SSH_PORT" ] || [ "$SSH_PORTS" = "$SSH_PORT" ]; then
    ok "SSH tetap di port $SSH_PORTS"; return 0
  fi
  if [ "$SSH_PORTS" != 22 ] && [ $SSH_PORT_EXPLICIT = 0 ]; then
    ok "SSH sudah memakai port custom $SSH_PORTS — tidak diubah (pakai --ssh-port untuk memaksa)"; return 0
  fi
  if ssh_listening "$SSH_PORT"; then
    warn "port $SSH_PORT sudah dipakai program lain — SSH tetap di port $SSH_PORTS"; return 0
  fi
  if ! fw_open_tcp "$SSH_PORT"; then
    warn "gagal membuka port $SSH_PORT di $FW — SSH tetap di port $SSH_PORTS"; return 0
  fi

  local bak; bak=$(mktemp -d)
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$bak"/ 2>/dev/null || cp -a /etc/ssh/sshd_config "$bak"/
  restore() {
    cp -a "$bak"/sshd_config /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/10-wg-setup-port.conf
    if [ -d "$bak"/sshd_config.d ]; then cp -a "$bak"/sshd_config.d/. /etc/ssh/sshd_config.d/; fi
  }

  sed -i -E 's/^[[:space:]]*Port[[:space:]]/#&/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
  if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" > /etc/ssh/sshd_config.d/10-wg-setup-port.conf
  else
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
  fi

  if ! sshd -t >>"$LOG" 2>&1; then
    restore; rm -rf "$bak"
    warn "konfigurasi SSH baru tidak valid — SSH tetap di port $SSH_PORTS"; return 0
  fi
  restart_ssh >>"$LOG" 2>&1 || true
  sleep 2
  if ssh_listening "$SSH_PORT"; then
    ok "SSH dipindah dari port $SSH_PORTS ke $SSH_PORT (sesi yang sedang aktif tidak terputus)"
    if [ "$FW" = ufw ] || [ "$FW" = firewalld ]; then
      ok "port $SSH_PORT dibuka di $FW; aturan lama untuk port $SSH_PORTS tidak dihapus"
    fi
    SSH_PORTS=$SSH_PORT
  else
    restore; restart_ssh >>"$LOG" 2>&1 || true
    warn "SSH gagal listen di port $SSH_PORT — dikembalikan ke port $SSH_PORTS"
  fi
  rm -rf "$bak"
}

setup_firewall() {
  case $FW in
    ufw)       setup_ufw ;;
    firewalld) setup_firewalld ;;
    nftables)  setup_nftables ;;
  esac
}

setup_ufw() {
  step "Menambahkan aturan ke UFW"
  { ufw allow "$WG_PORT/udp" comment 'WireGuard' \
    && ufw allow in on "$WG_IFACE" comment 'WireGuard clients' \
    && ufw route allow in on "$WG_IFACE" out on "$NIC" comment 'WireGuard NAT'; } >>"$LOG" 2>&1 \
    || die "gagal menambah aturan UFW (lihat $LOG)"
  ok "UFW: UDP $WG_PORT (WireGuard) + forwarding $WG_IFACE → $NIC; aturan lain tidak diubah"
}

setup_firewalld() {
  step "Menambahkan aturan ke firewalld"
  { firewall-cmd -q --permanent --zone="$FWD_ZONE" --add-port="$WG_PORT/udp" \
    && firewall-cmd -q --permanent --zone=trusted --add-interface="$WG_IFACE" \
    && firewall-cmd -q --reload; } >>"$LOG" 2>&1 \
    || die "gagal menambah aturan firewalld (lihat $LOG)"
  ok "firewalld: UDP $WG_PORT di zona $FWD_ZONE, $WG_IFACE di zona trusted"
}

setup_nftables() {
  step "Memasang firewall (nftables)"
  if [ -z "$SSH_PORTS" ]; then warn "port SSH tidak diketahui — firewall tidak dipasang agar tidak terkunci"; return 0; fi

  if [ -f /etc/nftables.conf ] && [ ! -f /etc/nftables.conf.orig ]; then
    cp -a /etc/nftables.conf /etc/nftables.conf.orig
  fi
  cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Firewall host (dibuat oleh wg-setup): hanya SSH dan WireGuard yang terbuka.
# Sengaja tanpa "flush ruleset" agar aturan NAT WireGuard (wg-quick) tidak terhapus.

table inet hostfw
delete table inet hostfw

table inet hostfw {
	chain input {
		type filter hook input priority filter; policy drop;

		iif "lo" accept
		ct state established,related accept
		ct state invalid drop

		# ICMP/ICMPv6 (wajib untuk IPv6 neighbor discovery & PMTU)
		meta l4proto { icmp, ipv6-icmp } accept

		tcp dport { ${SSH_PORTS// /, } } accept comment "SSH"
		udp dport $WG_PORT accept comment "WireGuard"

		# Lalu lintas dari klien VPN ke server
		iifname "$WG_IFACE" accept
	}
}
EOF
  nft -c -f /etc/nftables.conf >>"$LOG" 2>&1 || die "aturan nftables tidak valid (lihat $LOG)"
  nft -f /etc/nftables.conf
  systemctl enable nftables >>"$LOG" 2>&1 || true
  ok "terbuka: TCP ${SSH_PORTS// /, } (SSH), UDP $WG_PORT (WireGuard) — selain itu diblokir"
}

self_test() {
  step "Uji koneksi end-to-end"
  local t=wgsetup-selftest ns=wgst$$ c ip4 trace
  if ! wg-client add "$t" >/dev/null 2>&1; then warn "uji: gagal membuat klien uji"; return 0; fi
  c=/etc/wireguard/clients/$t.conf
  ip4=$(awk '/^Address/{sub(",","",$3); print $3}' "$c")

  ip netns add "$ns"
  ip link add "$ns-h" type veth peer name "$ns-n"
  ip link set "$ns-n" netns "$ns"
  ip addr add 198.18.250.1/30 dev "$ns-h"; ip link set "$ns-h" up
  ip -n "$ns" addr add 198.18.250.2/30 dev "$ns-n"
  ip -n "$ns" link set "$ns-n" up; ip -n "$ns" link set lo up
  ip -n "$ns" route add "$LOCAL4"/32 via 198.18.250.1
  ip -n "$ns" link add wgc type wireguard
  ip netns exec "$ns" wg set wgc \
    private-key <(awk '/^PrivateKey/{print $3}' "$c") \
    peer "$(cat /etc/wireguard/server.pub)" \
    preshared-key <(awk '/^PresharedKey/{print $3}' "$c") \
    endpoint "$LOCAL4:$WG_PORT" allowed-ips 0.0.0.0/0,::/0
  ip -n "$ns" addr add "$ip4" dev wgc
  ip -n "$ns" link set wgc mtu "$WG_MTU" up
  ip -n "$ns" route add default dev wgc
  if [ $HAS_V6 = 1 ]; then
    ip -n "$ns" addr add "$(awk '/^Address/{print $4}' "$c")" dev wgc
    ip -n "$ns" -6 route add default dev wgc
  fi
  sleep 1

  if ip netns exec "$ns" ping -c 3 -W 2 -q "$NET4.1" >/dev/null 2>&1; then ok "handshake & tunnel OK"
  else warn "uji: klien uji tidak bisa menjangkau $NET4.1 lewat tunnel"; fi
  trace=$(ip netns exec "$ns" curl -4 -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)
  if [[ "$trace" == *"ip="* ]]; then ok "internet IPv4 lewat VPN OK (keluar sebagai $(sed -n 's/^ip=//p' <<<"$trace"))"
  else warn "uji: internet IPv4 lewat VPN gagal"; fi
  if [ $HAS_V6 = 1 ]; then
    trace=$(ip netns exec "$ns" curl -6 -fsS --max-time 10 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null || true)
    if [[ "$trace" == *"ip="* ]]; then ok "internet IPv6 lewat VPN OK (keluar sebagai $(sed -n 's/^ip=//p' <<<"$trace"))"
    else warn "uji: internet IPv6 lewat VPN gagal"; fi
  fi
  if ip netns exec "$ns" ping -c 2 -W 2 -q -M do -s $((WG_MTU - 28)) 1.1.1.1 >/dev/null 2>&1; then ok "MTU $WG_MTU tanpa fragmentasi"
  else warn "uji: paket berukuran MTU $WG_MTU gagal lewat tunnel"; fi

  ip netns del "$ns" 2>/dev/null || true
  ip link del "$ns-h" 2>/dev/null || true
  wg-client remove "$t" >/dev/null 2>&1 || true
}

summary() {
  local ssh_port=${SSH_PORTS%% *}
  step "${G}Selesai!${N}"
  cat <<EOF
    Endpoint     : $ENDPOINT:$WG_PORT (UDP)
    SSH          : ssh -p ${ssh_port:-22} root@$ENDPOINT
    Jaringan VPN : $NET4.0/24${NET6:+, ${NET6}/64}   MTU $WG_MTU
    Firewall     : $FW
    Kelola klien : wg-client add <nama> | remove <nama> | list | show <nama>
    Config klien : /etc/wireguard/clients/
    Log setup    : $LOG
EOF
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo; echo "    ${Y}Perhatian:${N}"
    printf '     - %s\n' "${WARNINGS[@]}"
  fi
  cat <<EOF

    ${Y}PENTING:${N} jika provider punya firewall di panel kontrol, buka
    TCP ${ssh_port:-22} (SSH) dan UDP $WG_PORT (WireGuard) di sana.
EOF
  echo
  echo "${B}==> Config klien '$CLIENT_NAME' — scan QR dengan aplikasi WireGuard, atau salin teksnya ke file .conf${N}"
  echo
  wg-client show "$CLIENT_NAME"
}

main() {
  parse_args "$@"
  preflight
  install_packages
  detect_network
  detect_firewall
  setup_sysctl
  write_wireguard
  setup_ssh
  setup_firewall
  self_test
  wg-client add "$CLIENT_NAME" >/dev/null
  summary
}

main "$@"
