#!/bin/bash

echo "---- Temperatures ----"
cd /sys/bus/iio/devices/iio:device0 && \
for ch in in_temp*_raw; do
      base=${ch%_raw}
      raw=$(cat $ch)
      off=$(cat ${base}_offset)
      scl=$(cat ${base}_scale)
      # Result is in millidegrees C: (raw + offset) * scale
      awk -v r=$raw -v o=$off -v s=$scl \
          "BEGIN { printf \"%-30s %.2f °C\n\", \"$base\", (r + o) * s / 1000 }"
done


echo "---- List UIO ----"
for i in /sys/class/uio/uio*; do
  printf "%s\t%-12s @ %s\n" "$(basename $i)" "$(cat $i/name)" "$(cat $i/maps/map0/addr)"
done
