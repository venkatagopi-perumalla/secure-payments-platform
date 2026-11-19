# Rollback evidence

Measured on 18 November 2026 in the dev environment (eu-north-1).

| Situation | Mechanism | Measured result |
| --- | --- | --- |
| Release cannot start (revision 5, KeyError on start-up) | ECS deployment circuit breaker rolled back automatically after 3 of 3 failed tasks | About 4 minutes from approval (16:01) to rollback (16:05). 0 failed user requests: every health check in the 10-minute loop returned 200 |
| Release starts but is wrong (revision 6 back to 4) | Manual rollback workflow, approved in the production environment | 3 minutes 0 seconds from approval (16:24:52) to stable (16:27:52) |
| Database damaged | Point-in-time restore to a new instance | 14.2 minutes (13:47:08 to 14:01:19); restored copy encrypted and private |

Evidence: docs/evidence/ecs-circuit-breaker-rollback.png, deploy run "deploy" ended red with "deployment was likely rolled back by the deployment circuit breaker".

