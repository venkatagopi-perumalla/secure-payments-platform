# Controls evidence

| Control | Evidence |
| --- | --- |
| Private subnets with no internet route | `aws ec2 describe-route-tables` on payments-private shows only `10.30.0.0/16 local` |
| Security groups allow only named sources | Terraform `security_groups.tf`: internet to load balancer on 80, load balancer to app on 8000, app to database on 5432 |
