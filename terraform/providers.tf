provider "azurerm" {
  features {}

  # azurerm 4.x requires an explicit subscription. It is supplied by the
  # ARM_SUBSCRIPTION_ID environment variable (set by scripts/tf.sh and by the
  # workflows) rather than a variable, so it never lands in a tfvars file.

  # Providers are registered once during bootstrap; the deployment identities do
  # not re-register them on every run.
  resource_provider_registrations = "none"

  storage_use_azuread = true
}
