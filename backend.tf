terraform {
  backend "azurerm" {
    resource_group_name  = "FirstTfRG"
    storage_account_name = "bakendtfsree"
    container_name       = "backendtf"
    key                  = "prod.terraform.tfstate"
  }
}
