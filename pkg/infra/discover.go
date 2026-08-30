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
	// A comma-separated target is the shape a front end needs: "provision the base
	// and this product" is one operation with one progress bar, not two runs the
	// operator has to sequence correctly. Dependency order is still ours, so the
	// parts are reordered canonically — "midaz,infra-base" and "infra-base,midaz"
	// resolve identically, and neither can put a datastore before its VPC.
	if strings.Contains(target, ",") {
		return resolveComposite(layout, catalog, target)
	}
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

// resolveComposite resolves each comma-separated part and returns their union in
// canonical dependency order.
//
// The order comes from resolving "all" and filtering it, rather than from the
// order the parts were typed. That is the whole safety property: no spelling of a
// composite target can produce a run that applies a product before infra-base.
func resolveComposite(layout Layout, catalog Catalog, target string) ([]Stage, error) {
	wanted := map[string]bool{}
	var parts []string
	for _, part := range strings.Split(target, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if part == "all" {
			return nil, fmt.Errorf("infra: 'all' cannot be combined with another target\n"+
				"'all' already includes everything. Use it on its own, or list the parts:\n"+
				"  --target %s", strings.ReplaceAll(target, "all,", ""))
		}
		parts = append(parts, part)
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("infra: --target is empty")
	}
	if len(parts) == 1 {
		return Resolve(layout, catalog, parts[0])
	}

	// Resolve each part for its side effect: it validates the name and produces the
	// stages that part contributes. Collect their names.
	for _, part := range parts {
		stages, err := Resolve(layout, catalog, part)
		if err != nil {
			return nil, err
		}
		for _, stage := range stages {
			wanted[stage.Name] = true
		}
	}

	everything, err := Resolve(layout, catalog, "all")
	if err != nil {
		return nil, err
	}

	// A single-service target names a stage that "all" does not contain, because
	// "all" groups a product's services into one stage. Keep those verbatim, after
	// the canonical stages they cannot precede.
	ordered := make([]Stage, 0, len(wanted))
	for _, stage := range everything {
		if wanted[stage.Name] {
			ordered = append(ordered, stage)
			delete(wanted, stage.Name)
		}
	}
	if len(wanted) > 0 {
		for _, part := range parts {
			stages, err := Resolve(layout, catalog, part)
			if err != nil {
				return nil, err
			}
			for _, stage := range stages {
				if wanted[stage.Name] {
					ordered = append(ordered, stage)
					delete(wanted, stage.Name)
				}
			}
		}
	}
	return ordered, nil
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

// SkipUnconfiguredShared drops shared-tier engines that have no tfvars for this
// environment, and returns what it dropped.
//
// The shared tier is opt-in per engine, and the tfvars is how that opt-in is
// expressed: it holds five engines because five exist in AWS, not because any given
// environment wants all five. An installation whose products never touch Kafka has
// no reason to configure MSK — whose floor is three brokers, around US$105/month —
// and no reason to have "apply the shared tier" refuse to run because of it.
//
// This applies to the shared tier ONLY. For a product, every datastore under it is
// required by its chart, so a missing tfvars there is a real omission and stays an
// error.
func SkipUnconfiguredShared(stages []Stage, env string) ([]Stage, []string) {
	var skipped []string
	out := make([]Stage, 0, len(stages))

	for _, stage := range stages {
		if stage.Name != sharedResources {
			out = append(out, stage)
			continue
		}
		units := make([]Unit, 0, len(stage.Units))
		for _, unit := range stage.Units {
			if _, err := os.Stat(VarFile(unit, env)); err != nil {
				skipped = append(skipped, unit.Name)
				continue
			}
			units = append(units, unit)
		}
		if len(units) == 0 {
			continue
		}
		out = append(out, Stage{Name: stage.Name, Units: units})
	}
	return out, skipped
}
