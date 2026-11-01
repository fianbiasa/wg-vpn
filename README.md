# wg-vpn

Installer WireGuard VPN sekali jalan untuk VPS Ubuntu/Debian. Satu perintah, dan di akhir langsung muncul config klien beserta QR code-nya.

## Instal

Login ke VPS sebagai **root**, lalu jalankan:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fianbiasa/wg-vpn/main/wg-setup.sh)
```

Jika login sebagai user biasa dengan sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/fianbiasa/wg-vpn/main/wg-setup.sh | sudo bash
```

> **Penting:** jika provider VPS punya firewall di panel kontrol, buka **TCP port SSH** (default 2269) dan **UDP 51820** di sana.

## Opsi

Tambahkan di akhir perintah, contoh: `bash <(curl -fsSL URL) --keep-ssh-port --client hp-saya`.
Untuk mode `| sudo bash`, gunakan `| sudo bash -s -- --keep-ssh-port`.

| Opsi | Keterangan |
|---|---|
| `--ssh-port N` | Pindahkan SSH ke port N (default `2269`, hanya jika SSH masih di port 22) |
| `--keep-ssh-port` | Jangan ubah port SSH |
| `--wg-port N` | Port UDP WireGuard (default `51820`) |
| `--endpoint HOST` | Hostname/IP server di config klien (default: otomatis) |
| `--client NAMA` | Nama klien pertama (default `client1`) |
| `--dns "A, B"` | DNS untuk klien (default Cloudflare `1.1.1.1`) |
| `--no-firewall` | Jangan menyentuh firewall sama sekali |
| `--help` | Tampilkan bantuan |

## Yang dilakukan

- Memasang WireGuard dengan NAT **IPv4 + IPv6** (IPv6 otomatis jika VPS memilikinya) dan PresharedKey per klien.
- Mendeteksi otomatis interface, MTU, IPv6, dan endpoint (memakai hostname jika DNS-nya mengarah ke IP VPS, jika tidak memakai IP publik).
- **Firewall menyesuaikan yang sudah ada:**
  - UFW aktif → aturan WireGuard ditambahkan ke UFW, aturan lain tidak diubah.
  - firewalld aktif → port dibuka dan `wg0` dimasukkan ke zona trusted.
  - Tidak ada firewall aktif → dipasang nftables (hanya SSH + WireGuard yang terbuka).
- **Port SSH** dipindah ke 2269 hanya jika masih di port 22. Port baru dibuka di firewall dulu, lalu dicek benar-benar listen; jika gagal, otomatis dikembalikan.
- Tuning: BBR + fq, buffer UDP, MSS clamping, keepalive 25 detik.
- NAT dan MSS clamping berada di tabel nftables tersendiri, sehingga **tidak ikut terhapus** saat UFW/firewalld di-reload.
- **Uji otomatis** di akhir: klien sementara tersambung, lalu internet IPv4/IPv6 dan MTU lewat VPN diperiksa.
- Semua tetap aktif setelah reboot.

## Kelola klien

```bash
wg-client add hp-saya      # tambah klien (menampilkan QR code)
wg-client list             # daftar klien + status koneksi
wg-client show hp-saya     # tampilkan lagi config + QR
wg-client remove hp-saya   # hapus klien
```

Perubahan langsung berlaku tanpa restart dan tanpa memutus klien lain. Config klien tersimpan di `/etc/wireguard/clients/`.

## Kebutuhan

- Ubuntu 20.04+ atau Debian 11+
- VPS **KVM** (tidak bisa di OpenVZ/LXC karena butuh modul kernel WireGuard)
- Akses root

Sudah diuji di Ubuntu 24.04 dan Debian 12, masing-masing tanpa firewall, dengan UFW, dan dengan firewalld, termasuk setelah reload firewall dan reboot.

## Lokasi file di server

| File | Isi |
|---|---|
| `/etc/wireguard/wg0.conf` | Konfigurasi server + daftar peer |
| `/etc/wireguard/params` | Parameter (endpoint, port, subnet, DNS, MTU) |
| `/etc/wireguard/fw.sh` | NAT + MSS clamping (dipanggil wg-quick) |
| `/etc/nftables.conf` | Firewall host (hanya jika memakai mode nftables) |
| `/var/log/wg-setup.log` | Log instalasi |
