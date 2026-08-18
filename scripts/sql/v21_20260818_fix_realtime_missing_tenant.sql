-- Fix Supabase Realtime "tenant not found" auth error.
--
-- Root cause: self-hosted Supabase Realtime looks up its tenant by
-- `external_id` (table `_realtime.tenants`), matched against the
-- Kubernetes deployment name (`visionx-supabase-realtime`). The Helm
-- chart has no post-install hook to auto-seed this row, so a fresh or
-- reset environment ends up with only the default `realtime-dev` tenant
-- (auto-recreated by the Realtime app itself on every pod start), whose
-- `external_id` never matches the real deployment name. Every realtime
-- client then fails auth with:
--   [error] Auth error: tenant `visionx-supabase-realtime` not found
--
-- Fix: clone the existing tenant's config (jwt_secret, limits, and its
-- postgres_cdc_rls extension settings) into a new row keyed to the real
-- deployment name, leaving the original `realtime-dev` tenant untouched.
-- A reference environment where this was already fixed shows both rows
-- coexisting fine — Realtime only cares that a row matching the
-- requested external_id exists, not that unrelated rows are absent.
--
-- Idempotent: does nothing if a `visionx-supabase-realtime` tenant
-- already exists, or if there is no source tenant row to clone from
-- (fresh install with an empty `_realtime.tenants` table — seed it
-- manually first, see "Scenario 1: Fresh Deployment" in the source doc
-- below).
--
-- IMPORTANT: after this script runs, the Realtime pod must be restarted
-- for the fix to take effect — a raw SQL insert does not invalidate its
-- in-memory tenant cache/connection state:
--   kubectl rollout restart deployment/visionx-supabase-realtime -n supabase
--
-- Safe to run multiple times.
--
-- Full incident writeup + verification steps: visionx-vault
-- "02-Troubleshooting/Supabase Realtime Tenant Not Found.md". Source
-- troubleshooting doc: visionx-project/docs/troubleshoot/
-- supabase-realtime-tenant-not-found.md

DO $$
DECLARE
  target_external_id text := 'visionx-supabase-realtime';
  source_tenant_id uuid;
BEGIN
  IF EXISTS (
    SELECT 1 FROM _realtime.tenants WHERE external_id = target_external_id
  ) THEN
    RAISE NOTICE 'Tenant % already exists — nothing to do.', target_external_id;
    RETURN;
  END IF;

  SELECT id INTO source_tenant_id
  FROM _realtime.tenants
  ORDER BY inserted_at
  LIMIT 1;

  IF source_tenant_id IS NULL THEN
    RAISE NOTICE 'No existing tenant row to clone from — skipping. Needs a manual fresh-deployment seed (see source doc, Scenario 1).';
    RETURN;
  END IF;

  INSERT INTO _realtime.tenants (
    id, external_id, name, jwt_secret,
    max_concurrent_users, max_events_per_second, max_bytes_per_second,
    max_channels_per_client, max_joins_per_second, inserted_at, updated_at
  )
  SELECT gen_random_uuid(), target_external_id, target_external_id,
         jwt_secret, max_concurrent_users, max_events_per_second, max_bytes_per_second,
         max_channels_per_client, max_joins_per_second, NOW(), NOW()
  FROM _realtime.tenants
  WHERE id = source_tenant_id;

  INSERT INTO _realtime.extensions (
    id, type, settings, tenant_external_id, inserted_at, updated_at
  )
  SELECT gen_random_uuid(), e.type, e.settings, target_external_id, NOW(), NOW()
  FROM _realtime.extensions e
  JOIN _realtime.tenants t ON t.external_id = e.tenant_external_id
  WHERE t.id = source_tenant_id;

  RAISE NOTICE 'Seeded tenant % from existing tenant id %. Restart the Realtime pod for this to take effect.', target_external_id, source_tenant_id;
END
$$;
