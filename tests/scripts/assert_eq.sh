#!/bin/sh
# assert_eq <expected> <actual> <message>
exp="$1"; act="$2"; msg="$3"
if [ "$exp" != "$act" ]; then
  echo "ASSERT FAIL: $msg (expected='$exp' got='$act')" >&2
  exit 1
fi
