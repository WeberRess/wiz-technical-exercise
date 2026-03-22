# =====================================================================
# main.tf — Wiz Technical Exercise v5 — Azure
#
# Architecture:
#   PUBLIC  SUBNET (10.0.1.0/24) — mongodb-vm  (Debian 10 + MongoDB 4.4)
#   PRIVATE SUBNET (10.0.2.0/24) — k3s-vm      (Debian 12 + k3s)
#
# Intentional weak configurations (exercise requirements):
#   1. Debian 10 (EOL Jun 2024) + MongoDB 4.4 (EOL Feb 2024)
#   2. SSH exposed to the internet (0.0.0.0/0)
#   3. VM granted Contributor role (overly permissive)
#   4. Storage container with public read + listing
#   5. Container running as privileged
#   6. Pod bound to cluster-admin ClusterRoleBinding
# =====================================================================

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix               = random_string.suffix.result
  storage_account_name = "wizbackups${local.suffix}"
  acr_name             = "wizacr${local.suffix}"
}

# =====================================================================
# Resource Group
# =====================================================================
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# =====================================================================
# Virtual Network + Subnets
# =====================================================================
resource "azurerm_virtual_network" "main" {
  name                = "wiz-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Public subnet — MongoDB VM (SSH exposed to internet)
resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Private subnet — k3s Kubernetes VM (no public IP, internal only)
resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# =====================================================================
# NSG — MongoDB VM (public subnet)
# WEAK CONFIG: SSH open to the entire internet
# =====================================================================
resource "azurerm_network_security_group" "mongodb" {
  name                = "mongodb-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # WEAK CONFIG: SSH exposed to internet (0.0.0.0/0)
  security_rule {
    name                       = "Allow-SSH-Internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # MongoDB access restricted to private subnet (k3s nodes only)
  security_rule {
    name                       = "Allow-MongoDB-PrivateSubnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "27017"
    source_address_prefix      = "10.0.2.0/24"
    destination_address_prefix = "*"
  }
}

# =====================================================================
# NSG — k3s VM (private subnet)
# =====================================================================
resource "azurerm_network_security_group" "k3s" {
  name                = "k3s-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # SSH restricted to VNet only (management via az vm run-command)
  security_rule {
    name                       = "Allow-SSH-VNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/16"
    destination_address_prefix = "*"
  }

  # HTTP for the application (nginx ingress NodePort)
  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# =====================================================================
# Network Interfaces (no public IPs — sandbox policy restriction)
# =====================================================================
resource "azurerm_network_interface" "mongodb" {
  name                = "mongodb-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "mongodb" {
  network_interface_id      = azurerm_network_interface.mongodb.id
  network_security_group_id = azurerm_network_security_group.mongodb.id
}

resource "azurerm_network_interface" "k3s" {
  name                = "k3s-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "k3s" {
  network_interface_id      = azurerm_network_interface.k3s.id
  network_security_group_id = azurerm_network_security_group.k3s.id
}

# =====================================================================
# MongoDB VM — Debian 10 Buster (EOL June 2024 — intentional weak config)
# Placed in PUBLIC subnet with SSH exposed to internet
# =====================================================================
resource "azurerm_linux_virtual_machine" "mongodb" {
  name                = "mongodb-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_D2s_v3"
  admin_username      = var.vm_admin_username

  network_interface_ids = [azurerm_network_interface.mongodb.id]

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # WEAK CONFIG: Debian 10 (Buster) — EOL June 2024, 1+ year outdated
  source_image_reference {
    publisher = "Debian"
    offer     = "debian-10"
    sku       = "10"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    purpose = "wiz-exercise-mongodb"
    note    = "INTENTIONALLY-OUTDATED"
  }
}

# WEAK CONFIG: Contributor role — overly permissive (allows VM to create resources)
resource "azurerm_role_assignment" "vm_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.mongodb.identity[0].principal_id
}

resource "azurerm_role_assignment" "vm_storage" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.mongodb.identity[0].principal_id
}

# =====================================================================
# k3s VM — Debian 12 Bookworm
# Placed in PRIVATE subnet — no public IP, no internet-facing exposure
# Runs k3s Kubernetes + containerized todo-app
# =====================================================================
resource "azurerm_linux_virtual_machine" "k3s" {
  name                = "k3s-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_D2s_v3"  # 2 vCPU, 8GB RAM — required for k3s
  admin_username      = var.vm_admin_username

  network_interface_ids = [azurerm_network_interface.k3s.id]

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.vm_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Debian"
    offer     = "debian-12"
    sku       = "12"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    purpose = "wiz-exercise-kubernetes"
    subnet  = "private"
  }
}

resource "azurerm_role_assignment" "k3s_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_virtual_machine.k3s.identity[0].principal_id
}

# =====================================================================
# Storage Account — WEAK CONFIG: public read + listing
# =====================================================================
resource "azurerm_storage_account" "backups" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = true
  public_network_access_enabled   = true

  tags = {
    note = "INTENTIONALLY-PUBLIC-wiz-exercise"
  }
}

# WEAK CONFIG: container access type "container" = public read + listing
resource "azurerm_storage_container" "backups" {
  name                  = "mongodb-backups"
  storage_account_name  = azurerm_storage_account.backups.name
  container_access_type = "container"
}

# =====================================================================
# Azure Container Registry (ACR)
# =====================================================================
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = true
}

