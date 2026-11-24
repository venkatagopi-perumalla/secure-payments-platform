variable "api_domain" {
  type    = string
  default = "api.venkatagopiperumalla.com"
}

resource "aws_acm_certificate" "api" {
  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for o in aws_acm_certificate.api.domain_validation_options : o.resource_record_name]
}

output "acm_validation_record" {
  value = [for o in aws_acm_certificate.api.domain_validation_options : {
    name  = o.resource_record_name
    type  = o.resource_record_type
    value = o.resource_record_value
  }]
}

output "alb_dns_name" {
  value = module.service.alb_dns_name
}