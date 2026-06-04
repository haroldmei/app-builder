#!/usr/bin/env bash
# cogs-model.test.sh — asserts the unit-economics math is correct and the
# verdict flips with the inputs. Deterministic, network-free.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
M="$ROOT/scripts/cogs-model.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1 (got: $2)"; FAIL=$((FAIL+1)); }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.01}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }

# Scenario A: healthy defaults but cheap runs.
#   pfu = 3*0.5 + 0.4*1 = 1.90 ; cac = 1.90/0.03 = 63.33 ;
#   ltv = (49-12)/0.05 = 740 ; ratio = 11.68 -> HEALTHY
A="$(bash "$M" --json)"
near "$(echo "$A"|jq .per_free_user_cost)" 1.90 && ok "pfu = 1.90" || bad "pfu" "$(echo "$A"|jq .per_free_user_cost)"
near "$(echo "$A"|jq .cac)" 63.33 0.1 && ok "CAC = 63.33" || bad "CAC" "$(echo "$A"|jq .cac)"
near "$(echo "$A"|jq .ltv)" 740 0.1 && ok "LTV = 740" || bad "LTV" "$(echo "$A"|jq .ltv)"
near "$(echo "$A"|jq .ltv_cac)" 11.68 0.05 && ok "LTV:CAC = 11.68" || bad "ratio" "$(echo "$A"|jq .ltv_cac)"
[[ "$(echo "$A"|jq -r .verdict)" == "HEALTHY" ]] && ok "verdict HEALTHY" || bad "verdict" "$(echo "$A"|jq -r .verdict)"

# Scenario B: expensive runs + low conversion -> UNDERWATER.
#   pfu = 3*3 + 0.4*1 = 9.40 ; cac = 9.40/0.01 = 940 ; ltv=740 ; ratio=0.787
B="$(bash "$M" --cost-per-run 3.00 --conv 0.01 --json)"
near "$(echo "$B"|jq .cac)" 940 1 && ok "expensive CAC = 940" || bad "CAC-B" "$(echo "$B"|jq .cac)"
near "$(echo "$B"|jq .ltv_cac)" 0.787 0.01 && ok "ratio = 0.79" || bad "ratio-B" "$(echo "$B"|jq .ltv_cac)"
[[ "$(echo "$B"|jq -r .verdict)" == "UNDERWATER" ]] && ok "verdict UNDERWATER" || bad "verdict-B" "$(echo "$B"|jq -r .verdict)"

# Scenario C: contribution sign. Underwater scenario must lose money monthly.
CB="$(echo "$B"|jq .monthly_contribution)"
awk -v x="$CB" 'BEGIN{exit !(x<0)}' && ok "underwater contribution < 0 ($CB)" || bad "contribution-B" "$CB"
CA="$(echo "$A"|jq .monthly_contribution)"
awk -v x="$CA" 'BEGIN{exit !(x>0)}' && ok "healthy contribution > 0 ($CA)" || bad "contribution-A" "$CA"

# Scenario D: break-even conv consistency — at conv == breakeven, ratio ~= 1.
BE="$(echo "$B"|jq .breakeven_conv)"
D="$(bash "$M" --cost-per-run 3.00 --conv "$BE" --json)"
near "$(echo "$D"|jq .ltv_cac)" 1.0 0.02 && ok "at break-even conv, ratio ~= 1.0" || bad "breakeven" "$(echo "$D"|jq .ltv_cac)"

# Sweep smoke: must emit a base + 15-cell grid.
SW="$(bash "$M" --sweep --json)"
[[ "$(echo "$SW"|jq '.sweep|length')" -eq 15 ]] && ok "sweep grid has 15 cells" || bad "sweep" "$(echo "$SW"|jq '.sweep|length')"

echo "═══════════════════════════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "═══════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
