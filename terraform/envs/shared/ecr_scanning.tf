# Account-level setting: scan every payments-api image on push (basic scanning).
# Without a rule here, the repository's own scan_on_push setting is not applied.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "payments-api"
      filter_type = "WILDCARD"
    }
  }
}
