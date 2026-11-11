#!/bin/bash
# box1-docs#133 required check: the AMQ Broker MQTT listener answers on 127.0.0.1:1883 (bounded wait).
[ -f /etc/box1/site.env ] || { echo "not a site instance"; exit 0; }
for _ in $(seq 1 60); do
  if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/1883' 2>/dev/null; then echo "site MQTT listener up"; exit 0; fi
  sleep 5
done
echo "site MQTT listener not up after 300 s" >&2
exit 1
