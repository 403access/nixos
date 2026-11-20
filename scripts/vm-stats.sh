#!/usr/bin/env bash
#
# vm-stats.sh - read-only summary of host resources and one libvirt guest.
#
# Usage: scripts/vm-stats.sh [DOMAIN]
#        sudo scripts/vm-stats.sh win11-stock
#
# Samples for two seconds so the CPU numbers are live.  Nothing is written.
set -euo pipefail

domain="${1:-win11-stock}"
interval=1

die() { printf 'vm-stats: %s\n' "$*" >&2; exit 1; }
bold() { if [ -t 1 ]; then printf '\033[1m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }
human() {
  awk -v b="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i <= 2 ? "%.0f %s" : "%.1f %s"), b, u[i] }'
}
dur() {
  awk -v s="${1:-0}" 'BEGIN { d = int(s/86400); h = int((s%86400)/3600); m = int((s%3600)/60); o = ""; if (d > 0) o = o d "d "; if (d > 0 || h > 0) o = o h "h "; printf "%s%dm", o, m }'
}
pctshare() {
  awk -v a="${1:-0}" -v b="${2:-1}" 'BEGIN { if (b > 0) printf "%.0f%%", 100*a/b; else printf "n/a" }'
}

command -v virsh >/dev/null 2>&1 || die "virsh is not installed"
virsh dominfo "$domain" >/dev/null 2>&1 \
  || die "cannot query '$domain'; run as a member of libvirtd or with sudo"

# ---- host sample (1 s) ---------------------------------------------------
read -r _ hu hn hs hi hw hirq hsirq hst _ < /proc/stat
h_total1=$((hu + hn + hs + hi + hw + hirq + hsirq + hst))
h_idle1=$((hi + hw))
sleep "$interval"
read -r _ hu hn hs hi hw hirq hsirq hst _ < /proc/stat
h_total2=$((hu + hn + hs + hi + hw + hirq + hsirq + hst))
h_idle2=$((hi + hw))
host_busy=$(awk -v t1="$h_total1" -v t2="$h_total2" -v i1="$h_idle1" -v i2="$h_idle2" \
  'BEGIN { d = t2 - t1; if (d > 0) printf "%.0f", 100*(d - (i2 - i1))/d; else print 0 }')

ncpu=$(nproc)
read -r load1 load5 load15 _ < /proc/loadavg
uptime_s=$(cut -d. -f1 /proc/uptime)
mem_total=$(awk '/^MemTotal:/ {print $2*1024}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ {print $2*1024}' /proc/meminfo)
mem_used=$((mem_total - mem_avail))
swap_total=$(awk '/^SwapTotal:/ {print $2*1024}' /proc/meminfo)

# ---- guest config --------------------------------------------------------
state=$(virsh dominfo "$domain" | awk -F: '/^State:/ {gsub(/^ +| +$/, "", $2); print $2}')
vcpus=$(virsh dominfo "$domain" | awk -F: '/^CPU\(s\)/ {gsub(/ /, "", $2); print $2}')
autostart=$(virsh dominfo "$domain" | awk -F: '/^Autostart:/ {gsub(/^ +| +$/, "", $2); print $2}')

# ---- guest counters ------------------------------------------------------
declare -A S=()
while IFS='=' read -r key value; do
  key="${key// /}"
  case "$key" in
    *.*) S["$key"]="$value" ;;
  esac
done < <(virsh domstats "$domain" --state --cpu-total --balloon --block --interface)

mem_max_kib="${S[balloon.maximum]:-0}"
mem_rss_kib="${S[balloon.rss]:-0}"
cpu_ns1="${S[cpu.time]:-0}"

sleep "$interval"
cpu_ns2=$(virsh domstats "$domain" --cpu-total | awk -F= '/cpu.time=/ {print $2; exit}')
vm_cpu_now=$(awk -v a="$cpu_ns1" -v b="$cpu_ns2" -v n="$ncpu" -v t="$interval" \
  'BEGIN { d = (b - a)/1e9; if (n > 0 && t > 0) printf "%.1f", 100*d/(n*t); else print 0 }')
guest_cpu_s=$(awk -v ns="$cpu_ns2" 'BEGIN { printf "%.0f", ns/1e9 }')

vda_idx=""
net_idx=""
for key in "${!S[@]}"; do
  case "$key" in
    block.*.name)
      if [ "${S[$key]}" = "vda" ]; then
        vda_idx="${key#block.}"
        vda_idx="${vda_idx%.name}"
      fi
      ;;
    net.*.name)
      if [ -z "$net_idx" ]; then
        net_idx="${key#net.}"
        net_idx="${net_idx%.name}"
      fi
      ;;
  esac
done

disk_path="${S[block.$vda_idx.path]:-}"
disk_phys="${S[block.$vda_idx.physical]:-0}"
disk_cap="${S[block.$vda_idx.capacity]:-0}"
disk_rd="${S[block.$vda_idx.rd.bytes]:-0}"
disk_wr="${S[block.$vda_idx.wr.bytes]:-0}"

net_name="${S[net.$net_idx.name]:-}"
rx_b="${S[net.$net_idx.rx.bytes]:-0}"
rx_p="${S[net.$net_idx.rx.pkts]:-0}"
tx_b="${S[net.$net_idx.tx.bytes]:-0}"
tx_p="${S[net.$net_idx.tx.pkts]:-0}"

# ---- vCPU distribution ---------------------------------------------------
vcpu_lines=$(virsh vcpuinfo "$domain" | awk '
  /^VCPU:/ { v = $2 }
  /^CPU time:/ { t = $3; sub(/s$/, "", t); print "vCPU" v, t }')
top_fmt=""
while read -r name secs; do
  [ -n "$name" ] || continue
  top_fmt+="$name $(dur "$secs"), "
done < <(printf '%s\n' "$vcpu_lines" | sort -k2 -nr | head -3)
top_fmt="${top_fmt%, }"

# ---- ISO / removable media ----------------------------------------------
media=""
for key in "${!S[@]}"; do
  case "$key" in
    block.*.name)
      idx="${key#block.}"
      idx="${idx%.name}"
      [ "${S[$key]}" = "vda" ] && continue
      path="${S[block.$idx.path]:-}"
      if [ -n "$path" ]; then
        media+="${S[$key]} $path, "
      else
        media+="${S[$key]} empty, "
      fi
      ;;
  esac
done
media="${media%, }"

# ---- render --------------------------------------------------------------
bold "Host — $(hostname) — ${ncpu} threads · ${load1} ${load5} ${load15} load · up $(dur "$uptime_s")"
printf '  %-7s busy %s%% · swap %s\n' "CPU" "$host_busy" "$(human "$swap_total")"
printf '  %-7s %s / %s used · %s available\n' "Memory" "$(human "$mem_used")" "$(human "$mem_total")" "$(human "$mem_avail")"

fs_line() {
  local mount="$1" label="$2"
  if findmnt -n -o TARGET "$mount" >/dev/null 2>&1; then
    local used total use
    read -r used total use <<<"$(df -P -B1 "$mount" | awk 'NR==2 {print $3, $2, $5}')"
    printf '  %-7s %s / %s (%s)\n' "$label" "$(human "$used")" "$(human "$total")" "$use"
  fi
}
fs_line / "Root"
fs_line /mnt/tank "tank"

if command -v zpool >/dev/null 2>&1 && zpool list -H -o name tank >/dev/null 2>&1; then
  printf '  %-7s %s · %s capacity\n' "ZFS" \
    "$(zpool list -H -o health tank)" "$(zpool list -H -o cap tank)"
fi

printf '\n'
bold "VM $domain — $state — ${vcpus} vCPU · $(human $((mem_max_kib * 1024))) · autostart $autostart"
printf '  %-7s guest %s · now %.1f%% of host · busiest: %s\n' \
  "CPU" "$(dur "$guest_cpu_s")" "$vm_cpu_now" "${top_fmt:-n/a}"
printf '  %-7s %s RSS / %s configured · %s of host RAM\n' \
  "Memory" "$(human $((mem_rss_kib * 1024)))" "$(human $((mem_max_kib * 1024)))" \
  "$(pctshare "$mem_rss_kib" $((mem_total / 1024)))"
printf '  %-7s %s · %s allocated / %s virtual\n' \
  "Disk" "vda" "$(human "$disk_phys")" "$(human "$disk_cap")"
printf '  %-7s read %s · written %s\n' "" "$(human "$disk_rd")" "$(human "$disk_wr")"
printf '  %-7s %s · down %s (%s pkts) · up %s (%s pkts)\n' \
  "Network" "$net_name" "$(human "$rx_b")" "$rx_p" "$(human "$tx_b")" "$tx_p"
printf '  %-7s %s\n' "Media" "${media:-none}"
printf '  %-7s %s\n' "Image" "$disk_path"
