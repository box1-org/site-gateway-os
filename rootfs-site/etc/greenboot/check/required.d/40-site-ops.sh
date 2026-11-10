#!/bin/bash
# box1-docs#133 required check: site-ops answers its health endpoint (bounded wait).
[ -f /etc/box1/site.env ] || { echo "not a site instance"; exit 0; }
for _ in $(seq 1 36); do
  if curl -fsS --max-time 3 http://127.0.0.1:8081/q/health/ready >/dev/null 2>&1; then echo "site-ops ready"; exit 0; fi
  sleep 5
done
echo "site-ops not ready after 180 s" >&2
exit 1
