# [1.0.0-develop.2](https://github.com/LerianStudio/terraform-midaz-foundation/compare/v1.0.0-develop.1...v1.0.0-develop.2) (2025-04-24)


### Bug Fixes

* remove data region that is not used in aws/eks terraform files ([30ab12c](https://github.com/LerianStudio/terraform-midaz-foundation/commit/30ab12cf97a4fdf2429f8cf6ac936fc897226ab9))
* remove data sources not used in aws/eks terraform files ([7bfaf1f](https://github.com/LerianStudio/terraform-midaz-foundation/commit/7bfaf1ffcc8c14084122c5f9c58b48826ca29eb4))
* remove var.region that is not used in aws components ([52a0edc](https://github.com/LerianStudio/terraform-midaz-foundation/commit/52a0edcb3d6439caa2524bd86f1d25e35bb5defd))
* remove var.region that is not used in aws/elasticache terraform files ([7cfb2e1](https://github.com/LerianStudio/terraform-midaz-foundation/commit/7cfb2e156c6b3854dbf26cb473520f3f1afe02da))
* remove var.region that is not used in aws/elasticache terraform files ([387a39e](https://github.com/LerianStudio/terraform-midaz-foundation/commit/387a39ee5a4b75b6af05d5cc5fe91da080124959))


### Features

* aws infrastructure and documentation updates ([220013e](https://github.com/LerianStudio/terraform-midaz-foundation/commit/220013e96bf868195e7461915dfc78cd8b97584b))

# 1.0.0-develop.1 (2025-04-22)


### Bug Fixes

* **ci:** change semantic release to create pre-releases in develop branch ([880a565](https://github.com/LerianStudio/terraform-midaz-foundation/commit/880a565dada47abdc6b37275dcd426a2c00509d4))
* **ci:** change tflint config file ([101fb43](https://github.com/LerianStudio/terraform-midaz-foundation/commit/101fb43c567a863dd85824e55d6d31e8256587b6))
* **ci:** change tflint execution ([b1edf53](https://github.com/LerianStudio/terraform-midaz-foundation/commit/b1edf533319228b775906eeb83cf9be8ddadfacf))
* **ci:** change tflint execution ([b73bf0c](https://github.com/LerianStudio/terraform-midaz-foundation/commit/b73bf0c878ce144c5965eefe48956c14eeab5d58))
* **ci:** change tflint execution ([ded8e77](https://github.com/LerianStudio/terraform-midaz-foundation/commit/ded8e77f6c99162c09e1f8151562bdeab7109371))
* **ci:** change tflint execution and add semantic release dry_run to preview next release ([eaa7656](https://github.com/LerianStudio/terraform-midaz-foundation/commit/eaa7656f744dc2adaceff4e0023ff4c3a03b9abc))
* **ci:** change tflint execution to ignore .terraform folders ([f9fc0e4](https://github.com/LerianStudio/terraform-midaz-foundation/commit/f9fc0e42e4e9e1cd1643a4b50d7045beceff3ac4))
* **ci:** change the checkout steps based on PR or push events ([cec71a0](https://github.com/LerianStudio/terraform-midaz-foundation/commit/cec71a0a4e2f9d79c0caac4c946b3df952823058))
* **memorystore:** remove invalid env_vars output ([2f0c5b6](https://github.com/LerianStudio/terraform-midaz-foundation/commit/2f0c5b659ffacbc1d969dfe030bebf941bb9f071))
* **network:** configure random provider ([584a2b8](https://github.com/LerianStudio/terraform-midaz-foundation/commit/584a2b84f9ec1539d4274334f95ebb24c9bd2eb0))
* **network:** configure random provider ([ec21076](https://github.com/LerianStudio/terraform-midaz-foundation/commit/ec210761272aa9ca5c2ba7ff3e6b11528012f6b9))
* **security:** enhance AKS and network security configurations ([b92fcc9](https://github.com/LerianStudio/terraform-midaz-foundation/commit/b92fcc91f28745d7e60568bcaa3db36eece8c04f))
* **terraform:** resolve tflint warnings across modules ([09009ad](https://github.com/LerianStudio/terraform-midaz-foundation/commit/09009ad689c6cbd61ef3ae9133ea2f12ed4787db))


### Features

* initial release ([045fa30](https://github.com/LerianStudio/terraform-midaz-foundation/commit/045fa304f8481a1b26666f087e249105dacb6a15))


### BREAKING CHANGES

* First stable release of Terraform Midaz Foundation

- Add deployment helper script with multi-cloud support
- Configure git hooks with commitlint and tfsec checks
- Add comprehensive documentation and contribution guidelines
- Setup initial project structure with examples for AWS, Azure, and GCP
