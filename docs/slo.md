# Service level objective

| Item | Value |
| --- | --- |
| Service level indicator | Share of API requests that do not return a 5xx error, measured at the load balancer |
| Objective | 99.5 percent over 30 days |
| Error budget | 0.5 percent, about 3 hours 36 minutes of full failure per 30 days |
| Alerts | payments-5xx-rate above 2 percent for 2 of 3 minutes; payments-p95-latency above 1 second |
| Burn rule | If more than half the budget is gone before day 20 of the window, stop feature work and fix reliability |

Measured on 18 November 2026: during the deploy, the automatic rollback and the manual rollback, 0 health-check requests failed.
