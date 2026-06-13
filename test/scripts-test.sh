#!/bin/bash
# Unit tests for the bash logic shipped in the repmgr image. No cluster needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# --- syntax check every shipped script ---
for s in entrypoint.sh init-repmgr.sh repmgrd-entrypoint.sh service-updater.sh; do
  if bash -n "${ROOT}/${s}" 2>/dev/null; then ok "bash -n ${s}"; else bad "bash -n ${s}"; fi
done

# --- tl_to_int: WAL-filename timeline is HEX, must NOT be parsed as decimal ---
# Guards the #168 regression (a SQL ::int cast errored at TL 0x0A and was wrong
# from 0x10). Extract the shipped function and exercise the boundary cases.
sed -n '/^tl_to_int() {/,/^}/p' "${ROOT}/entrypoint.sh" > /tmp/.tl_fn.sh
if [ ! -s /tmp/.tl_fn.sh ]; then bad "extract tl_to_int from entrypoint.sh"; else
  ok "extract tl_to_int from entrypoint.sh"
  # shellcheck disable=SC1091
  source /tmp/.tl_fn.sh
  check() { # check INPUT EXPECTED
    got=$(tl_to_int "$1")
    if [ "$got" = "$2" ]; then ok "tl_to_int '$1' -> '$2'"; else bad "tl_to_int '$1' -> '$got' (want '$2')"; fi
  }
  check 00000001 1       # TL 1
  check 00000009 9       # TL 9  (last timeline where hex == decimal)
  check 0000000A 10      # TL 10 -- a ::int cast ERRORS here
  check 00000010 16      # TL 16 -- a ::int cast yields 10 here
  check 000000FF 255
  check 0000ABCD 43981
  check "" ""            # unreadable -> empty
  check "0000000G" ""    # non-hex -> empty
fi
rm -f /tmp/.tl_fn.sh

# --- entrypoint must not reintroduce the ::int-on-hex parse ---
if grep -q "from 1 for 8)::int" "${ROOT}/entrypoint.sh"; then
  bad "entrypoint.sh has no ::int-on-hex timeline cast"
else
  ok "entrypoint.sh has no ::int-on-hex timeline cast"
fi

echo "----"
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$fail"
