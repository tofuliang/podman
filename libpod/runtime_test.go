package libpod

import (
	"math/rand"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
)

func Test_generateName(t *testing.T) {
	state, path, _, err := getEmptyBoltState()
	assert.NoError(t, err)
	defer os.RemoveAll(path)
	defer state.Close()

	r := &Runtime{
		state: state,
	}

	// Test that (*Runtime).generateName returns different names
	// if called twice, even if the global RNG has the default
	// seed.
	n1, _ := r.generateName()
	rand.Seed(1)
	n2, _ := r.generateName()
	assert.NotEqual(t, n1, n2)
}
