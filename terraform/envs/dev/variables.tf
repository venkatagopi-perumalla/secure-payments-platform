variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "image_tag" {
  type        = string
  description = "Commit ID of the image to run on first create"
}
