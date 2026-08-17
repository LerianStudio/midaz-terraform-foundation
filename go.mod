module github.com/LerianStudio/lerian-terraform-foundation

// Same toolchain the wizard declares. The two repositories are built together —
// the wizard imports pkg/infra as a library — so a newer directive here would
// force a toolchain switch on the wizard's builders for no gain.
go 1.26.0

// Versions are the ones the wizard had already resolved for this exact code, so
// moving the package introduces no dependency bump. terraform-json is a direct
// import of pkg/infra (plan parsing); go-version is used to constrain the
// terraform binary discovery.
require (
	github.com/hashicorp/go-version v1.9.0
	github.com/hashicorp/terraform-exec v0.25.2
	github.com/hashicorp/terraform-json v0.27.2
)

require (
	github.com/apparentlymart/go-textseg/v15 v15.0.0 // indirect
	github.com/zclconf/go-cty v1.18.1 // indirect
	golang.org/x/text v0.33.0 // indirect
)
