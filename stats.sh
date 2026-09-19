#!/usr/bin/env bash
# One-shot telemetry for the acer.predator bar widget. Prints a single JSON
# line. Read-only: never wakes a suspended dGPU and never touches one that is
# not bound to the nvidia driver (same policy as predator-stats).
set -u
PS=/sys/devices/platform/acer-wmi/predator_sense

num()  { [[ ${1:-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf 'null'; }
str()  { printf '"%s"' "$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9 ._:,/+-')"; }
read1() { [[ -r $1 ]] && head -n1 "$1" 2>/dev/null || true; }
hwmon() { local f; for f in /sys/class/hwmon/hwmon*/name; do [[ $(<"$f") == "$1" ]] && { dirname "$f"; return; }; done; }

CORE=$(hwmon coretemp); ACER=$(hwmon acer)
cpu_t=""; [[ -n $CORE ]] && cpu_t=$(( $(read1 "$CORE/temp1_input") / 1000 ))
fan1=$(read1 "$ACER/fan1_input"); fan2=$(read1 "$ACER/fan2_input")

read -r mt ma < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)

# --- GPU ---
gpu_state="none"; gpu_drv=""; gpu_rt=""; gpu_ctl=""
g_t=""; g_u=""; g_w=""; g_mu=""; g_mt=""; g_mr=""; g_mf=""; g_name=""
for d in /sys/bus/pci/devices/*; do
  [[ $(read1 "$d/vendor") == 0x10de ]] || continue
  case "$(read1 "$d/class")" in 0x030000|0x030200) ;; *) continue ;; esac
  gpu_drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)
  gpu_rt=$(read1 "$d/power/runtime_status"); gpu_ctl=$(read1 "$d/power/control")
  if [[ $gpu_drv != nvidia ]]; then gpu_state="bound to ${gpu_drv:-none}"
  elif [[ $gpu_rt != active ]]; then gpu_state="suspended"
  else
    # Every nvidia-smi call resets the dGPU's idle timer, so polling it every
    # couple of seconds keeps it awake forever. Reuse a cached reading unless it
    # is older than $1 seconds (0 = always fresh, used while the panel is open).
    cache=${XDG_RUNTIME_DIR:-/tmp}/acer-predator-gpu.csv
    max_age=${1:-30}
    if [[ -s $cache ]] && (( $(date +%s) - $(stat -c %Y "$cache") < max_age )); then
      out=$(<"$cache")
    else
      out=$(timeout 2 nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total,memory.reserved,memory.free \
            --format=csv,noheader,nounits 2>/dev/null | head -n1)
      [[ -n $out ]] && printf '%s' "$out" > "$cache"
    fi
    if [[ -n $out ]]; then
      IFS=',' read -r g_name g_t g_u g_w g_mu g_mt g_mr g_mf <<<"$out"
      g_name=${g_name# }; g_t=${g_t// /}; g_u=${g_u// /}; g_w=${g_w// /}; g_mu=${g_mu// /}; g_mt=${g_mt// /}
      g_mr=${g_mr// /}; g_mf=${g_mf// /}
      gpu_state="active"
    else gpu_state="nvidia-smi unavailable"; fi
  fi
  break
done

bat_cap=$(read1 /sys/class/power_supply/BAT1/capacity)
bat_st=$(read1 /sys/class/power_supply/BAT1/status)
cpu_cap=$(read1 /sys/devices/system/cpu/intel_pstate/max_perf_pct)
cpu_khz=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | sort -n | tail -n1)
fan_set=$(read1 "$PS/fan_speed"); limit=$(read1 "$PS/battery_limiter")

printf '{"cpu_t":%s,"fan1":%s,"fan2":%s,"ram_total_kb":%s,"ram_avail_kb":%s,' \
  "$(num "$cpu_t")" "$(num "$fan1")" "$(num "$fan2")" "$(num "$mt")" "$(num "$ma")"
printf '"gpu":{"state":%s,"name":%s,"temp":%s,"util":%s,"power":%s,"mem_used":%s,"mem_total":%s,"mem_reserved":%s,"mem_free":%s,"driver":%s,"runtime":%s,"control":%s},' \
  "$(str "$gpu_state")" "$(str "$g_name")" "$(num "$g_t")" "$(num "$g_u")" "$(num "$g_w")" "$(num "$g_mu")" "$(num "$g_mt")" "$(num "$g_mr")" "$(num "$g_mf")" \
  "$(str "$gpu_drv")" "$(str "$gpu_rt")" "$(str "$gpu_ctl")"
printf '"cpu_cap":%s,"cpu_khz":%s,"fan_set":%s,"batt_limit":%s,"batt_cap":%s,"batt_status":%s}\n' \
  "$(num "$cpu_cap")" "$(num "$cpu_khz")" "$(str "$fan_set")" "$(num "$limit")" "$(num "$bat_cap")" "$(str "$bat_st")"
