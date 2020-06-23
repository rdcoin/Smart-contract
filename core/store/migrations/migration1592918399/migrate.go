package migration1592918399

import (
	"github.com/jinzhu/gorm"
)

// Migrate drops the redundant "status" column from job_runs
func Migrate(tx *gorm.DB) error {
	return tx.Exec(`
		ALTER TABLE job_runs DROP COLUMN status;
    `).Error
}
