ALTER TABLE "users"
  ADD COLUMN IF NOT EXISTS "membership_expiration_date" date,
  ADD COLUMN IF NOT EXISTS "membership_enforcement_policy" varchar(32),
  ADD COLUMN IF NOT EXISTS "membership_play_count" integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS "membership_last_annoy_date" date;

ALTER TABLE "sessions"
  ADD COLUMN IF NOT EXISTS "membership_enforcement_decision" boolean;

DO $$
DECLARE
  has_membership_status boolean;
  has_membership_type boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'users'
      AND column_name = 'membership_status'
  ) INTO has_membership_status;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'users'
      AND column_name = 'membership_type'
  ) INTO has_membership_type;

  IF has_membership_status AND NOT has_membership_type THEN
    ALTER TABLE "users" RENAME COLUMN "membership_status" TO "membership_type";
  ELSIF has_membership_status AND has_membership_type THEN
    UPDATE "users"
    SET "membership_type" = CASE
      WHEN "membership_status" IN ('lifetime', 'whitelisted') THEN "membership_status"
      ELSE 'normal'
    END;
    ALTER TABLE "users" DROP COLUMN "membership_status";
  ELSIF NOT has_membership_type THEN
    ALTER TABLE "users"
      ADD COLUMN "membership_type" varchar(20) NOT NULL DEFAULT 'normal';
  END IF;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'server_users'
      AND column_name = 'membership_override'
  ) THEN
    WITH consistent_overrides AS (
      SELECT
        "user_id",
        min("membership_status") AS membership_status,
        min("membership_expiration_date") AS membership_expiration_date,
        min("membership_enforcement_policy") AS membership_enforcement_policy
      FROM "server_users"
      WHERE "membership_override"
      GROUP BY "user_id"
      HAVING count(DISTINCT ROW(
        "membership_status",
        "membership_expiration_date",
        "membership_enforcement_policy"
      )) = 1
    )
    UPDATE "users" AS u
    SET
      "membership_type" = CASE
        WHEN overrides.membership_status IN ('lifetime', 'whitelisted') THEN overrides.membership_status
        ELSE 'normal'
      END,
      "membership_expiration_date" = overrides.membership_expiration_date,
      "membership_enforcement_policy" = overrides.membership_enforcement_policy
    FROM consistent_overrides AS overrides
    WHERE u."id" = overrides."user_id";

    UPDATE "users" AS u
    SET
      "membership_play_count" = account_state.play_count,
      "membership_last_annoy_date" = account_state.last_annoy_date
    FROM (
      SELECT
        "user_id",
        max("membership_play_count") AS play_count,
        max("membership_last_annoy_date") AS last_annoy_date
      FROM "server_users"
      GROUP BY "user_id"
    ) AS account_state
    WHERE u."id" = account_state."user_id";
  END IF;
END;
$$;

UPDATE "users"
SET "membership_type" = CASE
  WHEN "membership_type" IN ('lifetime', 'whitelisted') THEN "membership_type"
  ELSE 'normal'
END;

ALTER TABLE "server_users"
  DROP COLUMN IF EXISTS "membership_override",
  DROP COLUMN IF EXISTS "membership_status",
  DROP COLUMN IF EXISTS "membership_expiration_date",
  DROP COLUMN IF EXISTS "membership_enforcement_policy",
  DROP COLUMN IF EXISTS "membership_play_count",
  DROP COLUMN IF EXISTS "membership_last_annoy_date";
