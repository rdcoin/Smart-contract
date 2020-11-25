package web

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/pkg/errors"
	"github.com/smartcontractkit/chainlink/core/services"
	"github.com/smartcontractkit/chainlink/core/services/chainlink"
	"github.com/smartcontractkit/chainlink/core/services/job"
	"github.com/smartcontractkit/chainlink/core/services/offchainreporting"
	"github.com/smartcontractkit/chainlink/core/store/models"
	"github.com/smartcontractkit/chainlink/core/store/orm"
)

// EthRequestEventJobSpecsController manages OCR job spec requests.
type EthRequestEventJobSpecsController struct {
	App chainlink.Application
}

// Index lists all OCR job specs.
// Example:
// "GET <application>/ethrequestevent/specs"
func (erejsc *EthRequestEventJobSpecsController) Index(c *gin.Context) {
	jobs, err := erejsc.App.GetStore().ORM.OffChainReportingJobs()
	if err != nil {
		jsonAPIError(c, http.StatusInternalServerError, err)
		return
	}

	jsonAPIResponse(c, jobs, "offChainReportingJobSpec")
}

// Show returns the details of a OCR job spec.
// Example:
// "GET <application>/ethrequestevent/specs/:ID"
func (erejsc *EthRequestEventJobSpecsController) Show(c *gin.Context) {
	jobSpec := models.JobSpecV2{}
	err := jobSpec.SetID(c.Param("ID"))
	if err != nil {
		jsonAPIError(c, http.StatusUnprocessableEntity, err)
		return
	}

	jobSpec, err = erejsc.App.GetStore().ORM.FindOffChainReportingJob(jobSpec.ID)
	if errors.Cause(err) == orm.ErrorNotFound {
		jsonAPIError(c, http.StatusNotFound, errors.New("OCR job spec not found"))
		return
	}

	if err != nil {
		jsonAPIError(c, http.StatusInternalServerError, err)
		return
	}

	jsonAPIResponse(c, jobSpec, "offChainReportingJobSpec")
}

// Create validates, saves and starts a new OCR job spec.
// Example:
// "POST <application>/ethrequestevent/specs"
func (erejsc *EthRequestEventJobSpecsController) Create(c *gin.Context) {
	request := models.CreateOCRJobSpecRequest{}
	if err := c.ShouldBindJSON(&request); err != nil {
		jsonAPIError(c, http.StatusUnprocessableEntity, err)
		return
	}
	jobSpec, err := services.ValidatedOracleSpecToml(request.TOML)
	if err != nil {
		jsonAPIError(c, http.StatusBadRequest, err)
		return
	}
	config := erejsc.App.GetStore().Config
	if jobSpec.JobType() == offchainreporting.JobType && !config.Dev() && !config.FeatureOffchainReporting() {
		jsonAPIError(c, http.StatusNotImplemented, errors.New("The Offchain Reporting feature is disabled by configuration"))
		return
	}

	jobID, err := erejsc.App.AddJobV2(c.Request.Context(), jobSpec)
	if err != nil {
		if errors.Cause(err) == job.ErrNoSuchKeyBundle || errors.Cause(err) == job.ErrNoSuchPeerID || errors.Cause(err) == job.ErrNoSuchTransmitterAddress {
			jsonAPIError(c, http.StatusBadRequest, err)
			return
		}
		jsonAPIError(c, http.StatusInternalServerError, err)
		return
	}

	job, err := erejsc.App.GetStore().ORM.FindOffChainReportingJob(jobID)
	if err != nil {
		jsonAPIError(c, http.StatusInternalServerError, err)
		return
	}

	jsonAPIResponse(c, job, "offChainReportingJobSpec")
}

// Delete soft deletes an OCR job spec.
// Example:
// "DELETE <application>/ethrequestevent/specs/:ID"
func (erejsc *EthRequestEventJobSpecsController) Delete(c *gin.Context) {
	jobSpec := models.JobSpecV2{}
	err := jobSpec.SetID(c.Param("ID"))
	if err != nil {
		jsonAPIError(c, http.StatusUnprocessableEntity, err)
		return
	}

	err = erejsc.App.DeleteJobV2(c.Request.Context(), jobSpec.ID)
	if errors.Cause(err) == orm.ErrorNotFound {
		jsonAPIError(c, http.StatusNotFound, errors.New("JobSpec not found"))
		return
	}
	if err != nil {
		jsonAPIError(c, http.StatusInternalServerError, err)
		return
	}

	jsonAPIResponseWithStatus(c, nil, "offChainReportingJobSpec", http.StatusNoContent)
}
