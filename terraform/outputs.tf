output "mongodb_private_ip" {
  value = azurerm_network_interface.mongodb.private_ip_address
}

output "k3s_private_ip" {
  value = azurerm_network_interface.k3s.private_ip_address
}

output "mongodb_vm_name" {
  value = azurerm_linux_virtual_machine.mongodb.name
}

output "k3s_vm_name" {
  value = azurerm_linux_virtual_machine.k3s.name
}

output "storage_account_name" {
  value = azurerm_storage_account.backups.name
}

output "storage_public_url" {
  value = "${azurerm_storage_account.backups.primary_blob_endpoint}mongodb-backups"
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

