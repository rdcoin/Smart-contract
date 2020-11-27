package services

import (
	"github.com/guregu/null"
	"github.com/smartcontractkit/chainlink/core/services/pipeline"
	"github.com/smartcontractkit/chainlink/core/store/models"
)

// EthRequestEvent is a wrapper for `models.EthRequestEvent`, the DB
// representation of the job spec. It fulfills the job.Spec interface
// and has facilities for unmarshaling the pipeline DAG from the job spec text.
type EthRequestEvent struct {
	// TODO: Abstract these fields?
	Type            string          `toml:"type"`
	SchemaVersion   uint32          `toml:"schemaVersion"`
	Name            null.String     `toml:"name"`
	MaxTaskDuration models.Interval `toml:"maxTaskDuration"`

	models.OffchainReportingOracleSpec

	// The `jobID` field exists to cache the ID from the jobs table that joins
	// to the eth_request_events table.
	jobID int32

	// The `Pipeline` field is only used during unmarshaling.  A pipeline.TaskDAG
	// is a type that implements gonum.org/v1/gonum/graph#Graph, which means that
	// you can dot.Unmarshal(...) raw DOT source directly into it, and it will
	// be a fully-instantiated DAG containing information about all of the nodes
	// and edges described by the DOT.  Our pipeline.TaskDAG type has a method
	// called `.TasksInDependencyOrder()` which converts this node/edge data
	// structure into task specs which can then be saved to the database.
	Pipeline pipeline.TaskDAG `toml:"observationSource"`
}
