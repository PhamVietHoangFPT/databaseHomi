-- File: db/schema/2026-06-04-room-service-availability-access.sql
-- Muc dich: Minh hoa schema bo sung theo spec
--           docs/superpowers/specs/2026-06-04-room-service-availability-access-design.md
-- LUU Y: File nay la minh hoa, KHONG PHAI migration that.
--        Moi block CREATE TABLE/ALTER TABLE deu co comment
--        "-- MINH HOA, KHONG PHAI MIGRATION CHOT" ngay sau dinh nghia.

BEGIN;

-- =============================================================
-- 1) Bo sung cot vao rooms
-- =============================================================
-- MINH HOA, KHONG PHAI MIGRATION CHOT
ALTER TABLE rooms
ADD COLUMN IF NOT EXISTS access_mode access_mode_enum
    NOT NULL DEFAULT 'MANUAL_HANDOVER',
ADD COLUMN IF NOT EXISTS self_checkin_enabled BOOLEAN
    NOT NULL DEFAULT false,
ADD COLUMN IF NOT EXISTS access_visible_lead_minutes SMALLINT
    NULL,
ADD CONSTRAINT rooms_access_lead_range_chk
    CHECK (access_visible_lead_minutes IS NULL
           OR access_visible_lead_minutes BETWEEN 0 AND 1440);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
COMMENT ON COLUMN rooms.access_mode IS
    'MANUAL_HANDOVER | OWNER_SHARED_CODE | SMARTLOCK_DEVICE';
COMMENT ON COLUMN rooms.self_checkin_enabled IS
    'Co cho phep guest tu nhan phong qua app';
COMMENT ON COLUMN rooms.access_visible_lead_minutes IS
    'Cua so hien thi secret (phut). NULL = dung mac dinh theo access_mode. Clamp [0, 1440]';

-- =============================================================
-- 2) Bang room_access_configs
--    Luu source secret do owner/host cau hinh o cap room
-- =============================================================
-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE TABLE room_access_configs (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id                  UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    access_mode              access_mode_enum NOT NULL,
    -- Source secret (ciphertext) cho OWNER_SHARED_CODE
    source_secret_encrypted  TEXT NULL,
    source_secret_iv         VARCHAR(24) NULL,
    source_secret_tag        VARCHAR(32) NULL,
    source_secret_version    INT NOT NULL DEFAULT 1,
    -- Huong dan nhan phong (public)
    public_checkin_guide     TEXT NULL,
    -- Vi tri lockbox/key safe (co the encrypt)
    pickup_location_encrypted TEXT NULL,
    pickup_location_iv       VARCHAR(24) NULL,
    pickup_location_tag      VARCHAR(32) NULL,
    -- Smartlock device (chi dung khi access_mode = SMARTLOCK_DEVICE)
    smartlock_device_id      VARCHAR(100) NULL,
    smartlock_provider       VARCHAR(50) NULL,
    -- Audit
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID NULL,
    updated_by               UUID NULL,
    CONSTRAINT room_access_configs_one_per_room UNIQUE (room_id)
);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
COMMENT ON TABLE room_access_configs IS
    'Cau hinh nguon truy cap phong. Tach khoi metadata cong khai cua phong.';

-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE INDEX idx_room_access_configs_mode
    ON room_access_configs (access_mode)
    WHERE access_mode IN ('OWNER_SHARED_CODE', 'SMARTLOCK_DEVICE');

-- =============================================================
-- 3) Bang booking_access_deliveries
--    Luu snapshot delivery da phat hanh cho guest theo booking
-- =============================================================
-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE TABLE booking_access_deliveries (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id                UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
    room_access_config_id     UUID NOT NULL REFERENCES room_access_configs(id),
    access_mode               access_mode_enum NOT NULL,
    -- Delivery secret (ciphertext) cho OWNER_SHARED_CODE
    delivery_secret_encrypted TEXT NULL,
    delivery_secret_iv        VARCHAR(24) NULL,
    delivery_secret_tag       VARCHAR(32) NULL,
    -- Source version tai thoi diem phat hanh
    source_secret_version     INT NOT NULL,
    -- Cua so hien thi
    visible_from              TIMESTAMPTZ NOT NULL,
    visible_until             TIMESTAMPTZ NOT NULL,
    -- Trang thai phat hanh
    is_revoked                BOOLEAN NOT NULL DEFAULT false,
    revoked_at                TIMESTAMPTZ NULL,
    revoked_reason            VARCHAR(100) NULL,
    -- Audit
    first_viewed_at           TIMESTAMPTZ NULL,
    view_count                INT NOT NULL DEFAULT 0,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT booking_access_deliveries_one_per_booking UNIQUE (booking_id)
);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
COMMENT ON TABLE booking_access_deliveries IS
    'Snapshot delivery secret da phat hanh cho 1 booking cu the.';

-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE INDEX idx_booking_access_deliveries_window
    ON booking_access_deliveries (visible_from, visible_until)
    WHERE is_revoked = false;

-- =============================================================
-- 4) Bang access_delivery_audit_logs
--    Log moi lan guest app/doc server xem/truy cap
-- =============================================================
-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE TABLE access_delivery_audit_logs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    delivery_id  UUID NOT NULL REFERENCES booking_access_deliveries(id) ON DELETE CASCADE,
    actor_type   VARCHAR(20) NOT NULL,   -- GUEST | STAFF | SYSTEM
    actor_id     UUID NULL,
    action       VARCHAR(40) NOT NULL,   -- VIEW | DECRYPT | COPY | SCREENSHOT
    result       VARCHAR(20) NOT NULL,   -- SUCCESS | DENIED | ERROR
    ip_address   INET NULL,
    user_agent   TEXT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata     JSONB NULL
);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE INDEX idx_access_audit_delivery_time
    ON access_delivery_audit_logs (delivery_id, occurred_at DESC);

-- =============================================================
-- 5) Bang room_status_change_requests
--    Ho tro 3 muc dong phong
-- =============================================================
-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE TABLE room_status_change_requests (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id             UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    requested_by        UUID NOT NULL,
    request_type        VARCHAR(20) NOT NULL,    -- IMMEDIATE | SCHEDULED | EMERGENCY_OVERRIDE
    from_status         VARCHAR(20) NOT NULL,
    to_status           VARCHAR(20) NOT NULL,
    reason              TEXT NULL,
    -- Chi dung khi request_type = SCHEDULED
    effective_after_booking_id  UUID NULL REFERENCES bookings(id),
    effective_from_datetime     TIMESTAMPTZ NULL,
    -- Chi dung khi request_type = EMERGENCY_OVERRIDE
    override_reason_code        VARCHAR(40) NULL,
    override_workflow_opened    BOOLEAN NOT NULL DEFAULT false,
    -- Trang thai xu ly
    status              VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    -- PENDING | APPROVED | REJECTED | EXECUTED | FAILED
    executed_at         TIMESTAMPTZ NULL,
    failure_reason      TEXT NULL,
    -- Audit
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE INDEX idx_room_status_change_req_room_status
    ON room_status_change_requests (room_id, status);

-- MINH HOA, KHONG PHAI MIGRATION CHOT
CREATE INDEX idx_room_status_change_req_effective
    ON room_status_change_requests (effective_from_datetime)
    WHERE request_type = 'SCHEDULED' AND status = 'APPROVED';

COMMIT;
