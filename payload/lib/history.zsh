#!/usr/bin/env zsh
# Per-section duration history & stats.
#
# Sourced by run.zsh. Soft-fails on any I/O error: a broken history
# layer must NEVER turn a green run red.
#
# Public functions:
#   history_stats <history-file> <section>
#   history_recommend_poll <p95>
#   history_recommend_budget <p95>
#   history_is_outlier <duration> <p50>
#   history_append <history-file> <section> <duration> <result> <budget>
#   history_cap <history-file>
#
# Data shape — one JSON line per (section, run) in <history-file>:
#   {"ts":"<iso8601-utc>","section":"NN-slug","duration":<int>,"result":"PASS|FAIL|TIMEOUT|FAIL-missing","budget":<int>}
#
# Stats compute over PASS rows only.

# history_stats <history-file> <section>
#   Emits to stdout one of:
#     count=0
#     p50=<n> p95=<n> max=<n> count=<n>
history_stats() {
  local file="$1" section="$2"
  if [[ ! -f "$file" ]]; then
    print -- "count=0"
    return 0
  fi
  awk -v sect="$section" '
    BEGIN { n = 0 }
    # Pull "section":"..." and "duration":<int> and "result":"..." out of each line.
    # For "<key>":"<val>" — value runs from RSTART+len(key)+4 for RLENGTH-len(key)-5.
    # For "<key>":<int>   — value runs from RSTART+len(key)+3 for RLENGTH-len(key)-3.
    {
      if (match($0, /"section":"[^"]+"/)) {
        s = substr($0, RSTART+11, RLENGTH-12)
        if (s != sect) next
      } else { next }
      if (match($0, /"result":"[^"]+"/)) {
        r = substr($0, RSTART+10, RLENGTH-11)
        if (r != "PASS") next
      } else { next }
      if (match($0, /"duration":[0-9]+/)) {
        d = substr($0, RSTART+11, RLENGTH-11) + 0
        durs[n++] = d
      }
    }
    END {
      if (n == 0) { print "count=0"; exit }
      # Sort ascending.
      for (i = 0; i < n; i++) {
        for (j = i+1; j < n; j++) {
          if (durs[j] < durs[i]) { t = durs[i]; durs[i] = durs[j]; durs[j] = t }
        }
      }
      # p50 = ceil((n-1) * 0.5), p95 = ceil((n-1) * 0.95) — nearest-rank style.
      i50 = int((n - 1) * 0.5 + 0.5)
      i95 = int((n - 1) * 0.95 + 0.5)
      printf "p50=%d p95=%d max=%d count=%d\n", durs[i50], durs[i95], durs[n-1], n
    }
  ' "$file" 2>/dev/null || print -- "count=0"
}

# history_recommend_poll <p95>
#   Echoes integer seconds: max(15, min(120, ceil(p95 / 4))).
history_recommend_poll() {
  local p95="${1:-0}"
  if (( p95 <= 0 )); then
    print -- 15
    return 0
  fi
  local v=$(( (p95 + 3) / 4 ))   # ceil(p95/4)
  (( v < 15 )) && v=15
  (( v > 120 )) && v=120
  print -- "$v"
}

# history_recommend_budget <p95>
#   Echoes integer seconds: ceil(p95 * 1.5).
history_recommend_budget() {
  local p95="${1:-0}"
  if (( p95 <= 0 )); then
    print -- 0
    return 0
  fi
  print -- $(( (p95 * 3 + 1) / 2 ))
}

# history_is_outlier <duration> <p50>
#   Returns 0 (true) if p50 > 0 AND duration >= 2 * p50.
history_is_outlier() {
  local duration="${1:-0}" p50="${2:-0}"
  (( p50 > 0 && duration >= 2 * p50 ))
}

# history_append <history-file> <section> <duration> <result> <budget>
#   Appends one JSON line. Soft-fails on disk error.
history_append() {
  local file="$1" section="$2" duration="$3" result="$4" budget="$5"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 0
  local line
  printf -v line '{"ts":"%s","section":"%s","duration":%d,"result":"%s","budget":%d}\n' \
    "$ts" "$section" "$duration" "$result" "$budget"
  if ! print -rn -- "$line" >> "$file" 2>/dev/null; then
    print -u2 "WARN: failed to append history to $file"
  fi
  return 0
}

# history_cap <history-file>
#   Per-section: keep last 50 PASS rows + last 10 non-PASS rows.
#   Atomic via tmp + mv. Soft-fails.
history_cap() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp="${file}.tmp.$$"
  awk '
    function get_field(line, key,    re, rs, rl) {
      # String form: "<key>":"<val>"
      re = "\"" key "\":\"[^\"]+\""
      if (match(line, re)) {
        # Layout: "<key>":"<val>"  → "(1) + key + "(1) + :(1) + "(1) = 4 chars before val
        # And trailing "(1) = 5 chars total non-value.
        rs = RSTART + length(key) + 4
        rl = RLENGTH - length(key) - 5
        return substr(line, rs, rl)
      }
      # Integer form: "<key>":<int>
      re = "\"" key "\":[0-9]+"
      if (match(line, re)) {
        # Layout: "<key>":<int> → "(1) + key + "(1) + :(1) = 3 chars before val.
        rs = RSTART + length(key) + 3
        rl = RLENGTH - length(key) - 3
        return substr(line, rs, rl)
      }
      return ""
    }
    {
      sect = get_field($0, "section")
      res = get_field($0, "result")
      ts = get_field($0, "ts")
      if (sect == "" || res == "" || ts == "") next
      key = sect "|" (res == "PASS" ? "P" : "X")
      cnt[key]++
      idx = cnt[key]
      lines[key, idx] = $0
      tss[key, idx] = ts
    }
    END {
      # Per (sect, kind), keep last N by ts ascending. We append as encountered
      # but the file is already chronologically ordered (append-only). Use
      # array index order as the sort proxy.
      for (k in cnt) {
        n = cnt[k]
        split(k, parts, "|")
        kind = parts[2]
        keep_n = (kind == "P" ? 50 : 10)
        start = (n > keep_n ? n - keep_n + 1 : 1)
        for (i = start; i <= n; i++) {
          out_count++
          out_lines[out_count] = lines[k, i]
          out_ts[out_count] = tss[k, i]
        }
      }
      # Sort by ts ascending so file remains chronological.
      for (i = 1; i <= out_count; i++) {
        for (j = i+1; j <= out_count; j++) {
          if (out_ts[j] < out_ts[i]) {
            t = out_ts[i]; out_ts[i] = out_ts[j]; out_ts[j] = t
            t = out_lines[i]; out_lines[i] = out_lines[j]; out_lines[j] = t
          }
        }
      }
      for (i = 1; i <= out_count; i++) print out_lines[i]
    }
  ' "$file" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    print -u2 "WARN: history_cap failed to read $file (kept as-is)"
    return 0
  }
  if ! mv "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    print -u2 "WARN: history_cap failed to write $file (kept as-is)"
  fi
  return 0
}
