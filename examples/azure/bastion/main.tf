provider "azurerm" {
  features {}
}

# Dados do resource group onde estão os recursos do AKS
data "azurerm_resource_group" "aks" {
  name = "lerian-terraform-rg"
}

# Dados da subnet onde ficará o bastion
data "azurerm_virtual_network" "vnet" {
  name                = "midaz-vnet"
  resource_group_name = "lerian-terraform-rg"
}

data "azurerm_subnet" "subnet_aks_1" {
  name                 = "private-aks-subnet-1"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = "lerian-terraform-rg"
}

resource "azurerm_network_interface" "vm_admin_nic" {
  name                = "vm-admin-nic"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.subnet_aks_1.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_security_group" "vm_admin_nsg" {
  name                = "vm-admin-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "vm_admin_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.vm_admin_nic.id
  network_security_group_id = azurerm_network_security_group.vm_admin_nsg.id
}

resource "azurerm_linux_virtual_machine" "vm_admin" {
  name                = "aks-admin-vm"
  resource_group_name = data.azurerm_resource_group.aks.name
  location            = var.location
  size                = "Standard_B2s"
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.vm_admin_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<EOF
#!/bin/bash
apt-get update
apt-get install -y apt-transport-https curl jq
curl -s https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
apt-add-repository https://packages.microsoft.com/ubuntu/20.04/prod -y
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
az aks install-cli
snap install helm --classic
EOF
  )

  tags = var.tags
}

#################################
#    AZURE BASTION HOST         #
#################################
# Subnet específica para o Azure Bastion (precisa ter esse nome)
resource "azurerm_subnet" "bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = data.azurerm_resource_group.aks.name
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.12.0/27"]  # Escolha um bloco que não conflite, só para Bastion
}

# IP público para o Bastion
resource "azurerm_public_ip" "bastion_ip" {
  name                = "bastion-pip"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Azure Bastion Host
resource "azurerm_bastion_host" "bastion" {
  name                = "aks-bastion"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.aks.name

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_ip.id
  }
}

