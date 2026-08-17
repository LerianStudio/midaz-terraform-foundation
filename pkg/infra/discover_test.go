package infra

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeRepo builds a checkout shaped like lerian-terraform-foundation: the three
// ordered stacks plus products/<product>/<service>/main.tf.
func fakeRepo(t *testing.T, products map[string][]string) Layout {
	t.Helper()
	layout, err := NewLayout(t.TempDir())
	if err != nil {
		t.Fatalf("NewLayout: %v", err)
	}
	for _, dir := range []string{layout.BootstrapDir(), layout.VPCDir(), layout.EKSDir()} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), nil, 0o600); err != nil {
			t.Fatalf("write main.tf: %v", err)
		}
	}
	for product, services := range products {
		for _, service := range services {
			dir := filepath.Join(layout.ProductsDir(), product, service)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatalf("mkdir: %v", err)
			}
			if err := os.WriteFile(filepath.Join(dir, "main.tf"), nil, 0o600); err != nil {
				t.Fatalf("write main.tf: %v", err)
			}
		}
	}
	return layout
}

func TestDiscoverFindsOnlyTerraformRoots(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{
		"midaz":    {"postgres", "valkey", "rabbitmq"},
		"reporter": {"documentdb"},
	})

	// A service directory without a main.tf is not a root.
	if err := os.MkdirAll(filepath.Join(layout.ProductsDir(), "midaz", "notes"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Neither is anything Terraform itself left behind.
	cached := filepath.Join(layout.ProductsDir(), "midaz", ".terraform", "modules")
	if err := os.MkdirAll(cached, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cached, "main.tf"), nil, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Nor a product whose only content is a shared module.
	if err := os.MkdirAll(filepath.Join(layout.ProductsDir(), "_modules", "rds"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	if got, want := strings.Join(catalog.Names, ","), "midaz,reporter"; got != want {
		t.Errorf("Names = %q, want %q", got, want)
	}
	if got, want := strings.Join(catalog.Products["midaz"], ","), "postgres,rabbitmq,valkey"; got != want {
		t.Errorf("midaz services = %q, want %q (sorted, and without 'notes')", got, want)
	}
}

func TestResolveOrdersTheWholeRepository(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{
		"shared-resources": {"postgres", "valkey"},
		"midaz":            {"postgres", "valkey"},
		"reporter":         {"documentdb"},
	})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	stages, err := Resolve(layout, catalog, "all")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	want := []string{
		"bootstrap",
		"infra-base/vpc",
		"infra-base/eks",
		"shared-resources",
		"midaz",
		"reporter",
	}
	got := stageNames(stages)
	if strings.Join(got, " -> ") != strings.Join(want, " -> ") {
		t.Errorf("order = %v,\nwant     %v", got, want)
	}

	// shared-resources is ordered before the products and must not be repeated
	// among them.
	for _, stage := range stages[4:] {
		if stage.Name == sharedResources {
			t.Errorf("shared-resources appears twice: once as its own stage and once as a product")
		}
	}
}

func TestResolveTargets(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"postgres", "valkey"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	tests := []struct {
		target     string
		wantStages []string
		wantUnits  []string
	}{
		{"bootstrap", []string{"bootstrap"}, []string{"bootstrap"}},
		{"infra-base", []string{"infra-base/vpc", "infra-base/eks"},
			[]string{"infra-base/vpc", "infra-base/eks"}},
		{"infra-base/vpc", []string{"infra-base/vpc"}, []string{"infra-base/vpc"}},
		{"midaz", []string{"midaz"},
			[]string{"products/midaz/postgres", "products/midaz/valkey"}},
		{"midaz/valkey", []string{"midaz/valkey"}, []string{"products/midaz/valkey"}},
	}

	for _, test := range tests {
		t.Run(test.target, func(t *testing.T) {
			stages, err := Resolve(layout, catalog, test.target)
			if err != nil {
				t.Fatalf("Resolve(%q): %v", test.target, err)
			}
			if got := strings.Join(stageNames(stages), ","); got != strings.Join(test.wantStages, ",") {
				t.Errorf("stages = %q, want %q", got, test.wantStages)
			}
			var units []string
			for _, unit := range Units(stages) {
				units = append(units, unit.Name)
			}
			if got := strings.Join(units, ","); got != strings.Join(test.wantUnits, ",") {
				t.Errorf("units = %q, want %q", got, test.wantUnits)
			}
		})
	}
}

// The services of one product have no dependency on each other — separate state,
// separate locks — which is what lets them share a stage and run in parallel.
func TestResolvePutsEveryServiceOfAProductInOneStage(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"documentdb", "postgres", "rabbitmq", "valkey"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	stages, err := Resolve(layout, catalog, "midaz")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(stages) != 1 {
		t.Fatalf("got %d stages, want 1", len(stages))
	}
	if len(stages[0].Units) != 4 {
		t.Errorf("got %d units in the stage, want 4", len(stages[0].Units))
	}
}

func TestResolveRejectsUnknownTargets(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"postgres"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}

	tests := []struct {
		target string
		wantIn string
	}{
		{"ledger", "Discovered products: midaz"},
		{"midaz/oracle", `has no service "oracle"`},
	}
	for _, test := range tests {
		t.Run(test.target, func(t *testing.T) {
			_, err := Resolve(layout, catalog, test.target)
			if err == nil {
				t.Fatalf("Resolve(%q) succeeded, want an error", test.target)
			}
			if !strings.Contains(err.Error(), test.wantIn) {
				t.Errorf("error = %q, want it to contain %q", err, test.wantIn)
			}
		})
	}
}

func TestUnitStateKeyComesFromTheDirectory(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"postgres"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	stages, err := Resolve(layout, catalog, "midaz/postgres")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	unit := stages[0].Units[0]
	if want := "aws/products/midaz/postgres/terraform.tfstate"; unit.StateKey() != want {
		t.Errorf("StateKey = %q, want %q", unit.StateKey(), want)
	}
}

func TestForDestroyReversesTheOrderAndDropsBootstrap(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"postgres"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	stages, err := Resolve(layout, catalog, "all")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	reversed, warnings, err := ForDestroy(stages, "all")
	if err != nil {
		t.Fatalf("ForDestroy: %v", err)
	}

	want := []string{"midaz", "infra-base/eks", "infra-base/vpc"}
	if got := strings.Join(stageNames(reversed), ","); got != strings.Join(want, ",") {
		t.Errorf("order = %q, want %q", got, want)
	}
	if len(warnings) != 1 {
		t.Errorf("got %d warnings, want 1 about the skipped bootstrap: %v", len(warnings), warnings)
	}
	for _, unit := range Units(reversed) {
		if unit.Bootstrap {
			t.Error("bootstrap survived the destroy plan; its resources carry prevent_destroy")
		}
	}
}

func TestForDestroyRefusesToTargetBootstrapDirectly(t *testing.T) {
	layout := fakeRepo(t, map[string][]string{"midaz": {"postgres"}})
	catalog, err := Discover(layout)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	stages, err := Resolve(layout, catalog, "bootstrap")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}

	_, _, err = ForDestroy(stages, "bootstrap")
	if !errors.Is(err, ErrBootstrapDestroy) {
		t.Fatalf("error = %v, want ErrBootstrapDestroy", err)
	}
	// Refusing is only half the job: the message has to say what to do instead.
	if !strings.Contains(err.Error(), "terraform state rm") {
		t.Errorf("error = %q, want the teardown instruction", err)
	}
}

func stageNames(stages []Stage) []string {
	names := make([]string, 0, len(stages))
	for _, stage := range stages {
		names = append(names, stage.Name)
	}
	return names
}
