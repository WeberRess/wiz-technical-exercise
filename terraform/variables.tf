variable "resource_group_name" {
  default = "wiz-exercise-rg"
}

variable "location" {
  default = "uksouth"
}

variable "vm_admin_username" {
  default = "azureuser"
}

variable "vm_ssh_public_key" {
  type        = string
  description = "SSH public key content"
}

variable "your_name" {
  type        = string
  description = "Your name for the wizexercise.txt file"
}
