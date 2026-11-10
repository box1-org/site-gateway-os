#!/bin/bash
# box1-docs#133 required check: site-gateway is ready, which means PostgreSQL reachable, every
# outbox migration in this release applied, and the MQTT subscription connected. Kafka is
# not part of it, so a site whose link is down is not rolled back. Bounded wait.
[ -f /etc/box1/site.env ] || { echo "not a site instance"; exit 0; }
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/q/health/ready >/dev/null 2>&1; then echo "site-gateway ready"; exit 0; fi
  sleep 5
done
echo "site-gateway not ready after 300 s:" >&2
curl -sS --max-time 3 http://127.0.0.1:8080/q/health/ready >&2 || true
exit 1
