package main

import (
	"os"
	"testing"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// TestChecklistDemo is a rendering preview, not an assertion: run it with -v to
// see the tree the way an operator does. Kept because a format is easier to
// review by looking at it than by reading format strings.
func TestChecklistDemo(t *testing.T) {
	if os.Getenv("CHECKLIST_DEMO") == "" {
		t.Skip("set CHECKLIST_DEMO=1 to print the rendering preview")
	}
	unit := func(name string) infra.Unit { return infra.Unit{Name: name} }
	stages := []infra.Stage{
		{Name: "infra-base/vpc", Units: []infra.Unit{unit("infra-base/vpc")}},
		{Name: "infra-base/eks", Units: []infra.Unit{unit("infra-base/eks")}},
		{Name: "midaz", Units: []infra.Unit{
			unit("products/midaz/documentdb"), unit("products/midaz/postgres"),
			unit("products/midaz/rabbitmq"), unit("products/midaz/valkey"),
		}},
	}
	c := newChecklist(os.Stdout, stages)

	c.Update("infra-base/vpc", infra.StatusRunning, "planning...", "")
	c.Update("infra-base/vpc", infra.StatusOK, "42 to add\t16s", "")
	c.Update("infra-base/vpc", infra.StatusRunning, "applying...", "")
	c.Update("infra-base/vpc", infra.StatusOK, "42 added\t2m46s", "")

	c.Update("infra-base/eks", infra.StatusRunning, "planning...", "")
	c.Update("infra-base/eks", infra.StatusOK, "63 to add\t22s", "")
	c.Update("infra-base/eks", infra.StatusRunning, "applying...", "")
	c.Update("infra-base/eks", infra.StatusOK, "63 added\t14m34s", "")

	for _, n := range []string{"documentdb", "postgres", "rabbitmq", "valkey"} {
		c.Update("products/midaz/"+n, infra.StatusRunning, "planning...", "")
	}
	for _, n := range []string{"valkey", "postgres", "documentdb", "rabbitmq"} {
		c.Update("products/midaz/"+n, infra.StatusOK, "12 to add\t18s", "")
	}
	for _, n := range []string{"documentdb", "postgres", "rabbitmq", "valkey"} {
		c.Update("products/midaz/"+n, infra.StatusRunning, "applying...", "")
	}
	c.Update("products/midaz/valkey", infra.StatusOK, "12 added\t8m32s", "")
	c.Update("products/midaz/postgres", infra.StatusOK, "12 added\t8m41s", "")
	c.Update("products/midaz/documentdb", infra.StatusOK, "18 added\t11m04s", "")
	c.Update("products/midaz/rabbitmq", infra.StatusFail, "AccessDenied: mq:CreateBroker\nsecond line dropped", "")
}
