-- Pastikan extension UUID aktif
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Create DICOM Devices Table (Base)
CREATE TABLE IF NOT EXISTS dicom_devices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ae_title VARCHAR(16) NOT NULL,
    host VARCHAR(253) NOT NULL,
    port INTEGER NOT NULL CHECK (port >= 1 AND port <= 65535),
    device_type VARCHAR(50) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for devices
CREATE INDEX IF NOT EXISTS idx_dicom_devices_type ON dicom_devices(device_type);
CREATE INDEX IF NOT EXISTS idx_dicom_devices_ae_title ON dicom_devices(ae_title);

-- 2. Update DICOM Devices (Add 'printer_config', 'name', and 'active')
-- Menggunakan IF NOT EXISTS agar aman dijalankan berulang
ALTER TABLE dicom_devices ADD COLUMN IF NOT EXISTS printer_config JSONB DEFAULT NULL;
ALTER TABLE dicom_devices ADD COLUMN IF NOT EXISTS name VARCHAR(255) DEFAULT NULL;
ALTER TABLE dicom_devices ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT TRUE NOT NULL;

-- Update existing NULL active status to TRUE (Backward compatibility)
UPDATE dicom_devices SET active = TRUE WHERE active IS NULL;

-- Comments & Indexes for new columns
COMMENT ON COLUMN dicom_devices.printer_config IS 'Printer-specific configuration (medium types, film sizes, layouts, etc.)';
COMMENT ON COLUMN dicom_devices.name IS 'Human-readable device name for easier identification';
COMMENT ON COLUMN dicom_devices.active IS 'Device active status. Only active devices can be used for sending DICOM studies.';
CREATE INDEX IF NOT EXISTS idx_dicom_devices_name ON dicom_devices(name);
CREATE INDEX IF NOT EXISTS idx_dicom_devices_active ON dicom_devices(active);


-- 3. Create DICOM Jobs Table (Realtime)
CREATE TABLE IF NOT EXISTS dicom_jobs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_type VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    error TEXT,
    logs JSONB DEFAULT '[]'::jsonb,
    result JSONB,
    study_uid VARCHAR(255),
    target_device_id UUID REFERENCES dicom_devices(id),
    created_by VARCHAR(255),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for jobs
CREATE INDEX IF NOT EXISTS idx_dicom_jobs_status ON dicom_jobs(status);
CREATE INDEX IF NOT EXISTS idx_dicom_jobs_job_type ON dicom_jobs(job_type);
CREATE INDEX IF NOT EXISTS idx_dicom_jobs_created_at ON dicom_jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dicom_jobs_study_uid ON dicom_jobs(study_uid);
CREATE INDEX IF NOT EXISTS idx_dicom_jobs_target_device_id ON dicom_jobs(target_device_id);

-- 4. Trigger & Automation for Jobs Timestamp
CREATE OR REPLACE FUNCTION update_dicom_jobs_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_dicom_jobs_updated_at ON dicom_jobs;
CREATE TRIGGER trigger_update_dicom_jobs_updated_at
    BEFORE UPDATE ON dicom_jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_dicom_jobs_updated_at();

-- 5. Enable Realtime (Supabase Specific)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        -- Check if table is already a member of the publication
        IF NOT EXISTS (
            SELECT 1 
            FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' 
            AND tablename = 'dicom_jobs'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE dicom_jobs;
        ELSE
            RAISE NOTICE 'Table dicom_jobs is already a member of supabase_realtime publication.';
        END IF;
    ELSE
        RAISE NOTICE 'supabase_realtime publication does not exist. Real-time will need to be enabled manually.';
    END IF;
END $$;
