package infra

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// sharedResources is the datastore tier that products running in shared mode
// depend on. It lives under products/ like everything else, so it is discovered
// like everything else, but it is ordered before the real products.
const sharedResources = "shared-resources"

// ErrBootstrapDestroy is returned when a run would destroy the bootstrap stack.
var ErrBootstrapDestroy = fmt.Errorf("infra: bootstrap cannot be destroyed")

// Catalog is what the filesystem says exists right now.
type Catalog struct {
	// Products maps a product name to its service directory names, sorted.
	Products map[string][]string
	// Names are the product names, sorted, shared-resources included.
	Names []string
}

// Discover walks examples/aws/products for Terraform roots. A directory counts
// when it is exactly products/<product>/<service> and holds a main.tf; pinning
// both ends of the depth is what keeps _modules, .terraform and any future
// nesting out of the catalogue.
//
// Nothing here is hardcoded: a new product is deployable the moment its directory
// exists.
func Discover(layout Layout) (Catalog, error) {
	root := layout.ProductsDir()
	catalog := Catalog{Products: map[string][]string{}}

	products, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return catalog, fmt.Errorf("infra: no products directory at %s\n"+
				"This does not look like a lerian-terraform-foundation checkout on the AWS v2\n"+
				"layout. Point --repo at the repository root.", layout.RepoRel(root))
		}
		return catalog, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(root), err)
	}

	for _, product := range products {
		if !product.IsDir() || strings.HasPrefix(product.Name(), ".") {
			continue
		}
		services, err := os.ReadDir(filepath.Join(root, product.Name()))
		if err != nil {
			return catalog, fmt.Errorf("infra: cannot read %s: %w",
				layout.RepoRel(filepath.Join(root, product.Name())), err)
		}
		var found []string
		for _, service := range services {
			if !service.IsDir() || strings.HasPrefix(service.Name(), ".") {
				continue
			}
			main := filepath.Join(root, product.Name(), service.Name(), "main.tf")
			if info, err := os.Stat(main); err == nil && !info.IsDir() {
				found = append(found, service.Name())
			}
		}
		if len(found) == 0 {
			continue
		}
		sort.Strings(found)
		catalog.Products[product.Name()] = found
		catalog.Names = append(catalog.Names, product.Name())
	}
	sort.Strings(catalog.Names)
	return catalog, nil
}

// ProductNames returns the products excluding the shared datastore tier, which is
// a stage of its own rather than a product somebody deploys on purpose.
func (c Catalog) ProductNames() []string {
	names := make([]string, 0, len(c.Names))
	for _, name := range c.Names {
		if name != sharedResources {
			names = append(names, name)
		}
	}
	return names
}

// Resolve turns an operator's --target into the ordered stages a run walks.
//
// The order is the dependency order of the repository and is not configurable:
//
//	bootstrap -> infra-base/vpc -> infra-base/eks -> shared-resources -> products
//
// vpc is a hard prerequisite for everything below it, because every datastore
// resolves the VPC and its Type=database subnets by tag.
func Resolve(layout Layout, catalog Catalog, target string) ([]Stage, error) {
	unit := func(dir string) Unit {
		return Unit{Dir: dir, Name: layout.rel(dir), Bootstrap: dir == layout.BootstrapDir()}
	}
	stage := func(name string, dirs ...string) Stage {
		units := make([]Unit, 0, len(dirs))
		for _, dir := range dirs {
			units = append(units, unit(dir))
		}
		return Stage{Name: name, Units: units}
	}
	productStage := func(product string) Stage {
		services := catalog.Products[product]
		dirs := make([]string, 0, len(services))
		for _, service := range services {
			dirs = append(dirs, filepath.Join(layout.ProductsDir(), product, service))
		}
		return stage(product, dirs...)
	}

	switch target {
	case "all":
		stages := []Stage{
			stage("bootstrap", layout.BootstrapDir()),
			stage("infra-base/vpc", layout.VPCDir()),
			stage("infra-base/eks", layout.EKSDir()),
		}
		if _, ok := catalog.Products[sharedResources]; ok {
			stages = append(stages, productStage(sharedResources))
		}
		for _, product := range catalog.ProductNames() {
			stages = append(stages, productStage(product))
		}
		return stages, nil
	case "bootstrap":
		return []Stage{stage("bootstrap", layout.BootstrapDir())}, nil
	case "infra-base":
		return []Stage{
			stage("infra-base/vpc", layout.VPCDir()),
			stage("infra-base/eks", layout.EKSDir()),
		}, nil
	case "infra-base/vpc":
		return []Stage{stage("infra-base/vpc", layout.VPCDir())}, nil
	case "infra-base/eks":
		return []Stage{stage("infra-base/eks", layout.EKSDir())}, nil
	}

	product, service, hasService := strings.Cut(target, "/")
	services, known := catalog.Products[product]
	if !known {
		return nil, fmt.Errorf("infra: unknown target %q\n"+
			"%q is not a product under %s with a service holding a main.tf.\n"+
			"Non-product targets: bootstrap, infra-base, infra-base/vpc, infra-base/eks, all.\n"+
			"Discovered products: %s",
			target, product, layout.RepoRel(layout.ProductsDir()),
			strings.Join(catalog.Names, ", "))
	}

	if !hasService {
		return []Stage{productStage(product)}, nil
	}
	for _, candidate := range services {
		if candidate == service {
			return []Stage{stage(target,
				filepath.Join(layout.ProductsDir(), product, service))}, nil
		}
	}
	return nil, fmt.Errorf("infra: unknown target %q\n"+
		"%q exists but has no service %q.\nAvailable services: %s",
		target, product, service, strings.Join(services, ", "))
}

// ForDestroy walks the dependency graph backwards and takes bootstrap out of it.
//
// The bucket and the lock table carry prevent_destroy = true, so a destroy of
// bootstrap fails by design: losing the state means Terraform no longer knows what
// it owns. Asking for exactly that is an error; sweeping it up in a wider target is
// a warning and the stack is skipped.
func ForDestroy(stages []Stage, target string) ([]Stage, []BackendWarning, error) {
	if target == "bootstrap" {
		return nil, nil, fmt.Errorf("%w\n"+
			"aws_s3_bucket.tfstate and aws_dynamodb_table.tfstate_lock carry\n"+
			"prevent_destroy = true, so 'terraform destroy' fails by design — losing state\n"+
			"means Terraform no longer knows what it owns.\n\n"+
			"To tear down a validation environment on purpose, follow\n"+
			"examples/aws/bootstrap/README.md, section \"Teardown\", Option A: detach the two\n"+
			"resources with 'terraform state rm', then delete the bucket and the table with\n"+
			"the AWS CLI.", ErrBootstrapDestroy)
	}

	var warnings []BackendWarning
	kept := make([]Stage, 0, len(stages))
	for _, stage := range stages {
		units := make([]Unit, 0, len(stage.Units))
		for _, unit := range stage.Units {
			if unit.Bootstrap {
				warnings = append(warnings, "skipping bootstrap in the destroy plan "+
					"(prevent_destroy; see examples/aws/bootstrap/README.md)")
				continue
			}
			units = append(units, unit)
		}
		if len(units) == 0 {
			continue
		}
		kept = append(kept, Stage{Name: stage.Name, Units: units})
	}

	reversed := make([]Stage, 0, len(kept))
	for i := len(kept) - 1; i >= 0; i-- {
		reversed = append(reversed, kept[i])
	}
	return reversed, warnings, nil
}
