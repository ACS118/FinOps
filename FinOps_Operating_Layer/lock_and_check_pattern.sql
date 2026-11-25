-- ============================================================================
-- LOCK-AND-CHECK PATTERN: seal a closed month of cloud cost, then keep checking it
-- Works with any cloud provider and any SQL warehouse. Nothing here is specific to one company.
-- ============================================================================
--
-- THE FOUR RULES (these matter more than the SQL)
--   1. Seal a closed month once, after a person has approved it.
--   2. Never edit a sealed row. If a month must change, add a new, labelled version with a written reason.
--   3. Recompute every sealed month from the raw billing export on a schedule, and compare.
--   4. Name the person who reads the drift message. A check nobody reads is not a check.
--
-- HOW TO ADAPT IT (two things differ between practitioners)
--   A. Your cloud provider decides the columns of your billing export.
--      Fix: map the export to a few columns in ONE view (Part 1). Everything below reads only that view.
--      If your export follows the FOCUS standard, the mapping is a few lines. If not, map by hand.
--   B. Your warehouse decides some syntax.
--      Fix: this file sticks to a plain SQL subset. The few places that differ are in the table at the end.
--
-- TESTED: the core (Parts 2 to 5) was run on DuckDB, which follows PostgreSQL syntax.
-- NOT TESTED on Snowflake, BigQuery, Redshift or Databricks. Try it on a copy before you rely on it.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- PART 1. MAP YOUR BILLING EXPORT TO ONE VIEW. This is the only provider-specific step.
-- ----------------------------------------------------------------------------
-- Replace <your_billing_export> and the expressions on the right.
-- FOCUS-style export: usage_date <- ChargePeriodStart, service <- ServiceName, cost <- BilledCost.
--
-- Decide ONCE which cost you seal (billed cost, or cost after discounts and credits) and use that
-- same cost every time. The check only works if the seal and the check use the same definition.
--
-- usage_month must be a DATE holding the first day of the month. How to compute it is in the table
-- at the end (DATE_TRUNC takes different arguments in different warehouses).
--
-- CREATE VIEW billing_source_view AS
-- SELECT
--   CAST(<charge start timestamp> AS DATE)             AS usage_date,
--   <first day of that month, as a DATE>               AS usage_month,
--   <service name column>                              AS service,
--   <cost column>                                      AS cost
-- FROM <your_billing_export>;


-- ----------------------------------------------------------------------------
-- PART 2. THREE SMALL TABLES, ONE OF THEM HOLDING ONE ROW OF SETTINGS
-- ----------------------------------------------------------------------------
-- actuals_locked  one row per month and service, written once (the locked record)
-- drift_log       one row per month, service and check, so you can see how a locked month moves
-- lock_config     one row: which month to seal, who approved it, how big a gap you accept
--
-- Types: BigQuery needs STRING where this file says VARCHAR(255). The others accept VARCHAR.

CREATE TABLE IF NOT EXISTS actuals_locked (
  month      DATE,
  service    VARCHAR(255),
  cost       DECIMAL(18, 2),
  locked_at  TIMESTAMP,
  locked_by  VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS drift_log (
  checked_at   TIMESTAMP,
  month        DATE,
  service      VARCHAR(255),
  locked_cost  DECIMAL(18, 2),
  source_cost  DECIMAL(18, 2),
  diff         DECIMAL(18, 2),
  diff_pct     DECIMAL(18, 6),
  status       VARCHAR(10)       -- OK or DRIFT
);

CREATE TABLE IF NOT EXISTS lock_config (
  month_to_seal  DATE,            -- first day of the month to seal, for example DATE '2026-01-01'
  locked_by      VARCHAR(255),    -- the person who approved it
  tolerance_abs  DECIMAL(18, 2)   -- the largest gap per month and service that you accept without a flag
);
-- Keep exactly one row in lock_config. To change it:
--   DELETE FROM lock_config;
--   INSERT INTO lock_config VALUES (DATE '2026-01-01', 'Your Name', 5.00);


-- ----------------------------------------------------------------------------
-- PART 3. SEAL: write the closed month once, after a person has approved it
-- ----------------------------------------------------------------------------
-- Safe to run twice: rows that already exist are skipped, so a second run changes nothing.
-- This uses INSERT ... WHERE NOT EXISTS rather than MERGE because every warehouse supports it.
-- Run it only when the month is complete. Billing data can land after month end.

INSERT INTO actuals_locked (month, service, cost, locked_at, locked_by)
SELECT s.usage_month, s.service, s.cost, CURRENT_TIMESTAMP, c.locked_by
FROM (
  SELECT usage_month, service, SUM(cost) AS cost
  FROM billing_source_view
  GROUP BY usage_month, service
) s
JOIN lock_config c ON s.usage_month = c.month_to_seal
WHERE NOT EXISTS (
  SELECT 1 FROM actuals_locked t
  WHERE t.month = s.usage_month AND t.service = s.service
);


-- ----------------------------------------------------------------------------
-- PART 4. CHECK: recompute every sealed month from the raw export and compare
-- ----------------------------------------------------------------------------
-- Run this on a schedule (see the table at the end), not only when someone remembers.
-- It compares at the level the seal was written (month and service). The FULL join catches both
-- a service whose cost changed and a service that appeared in the export after the seal.

INSERT INTO drift_log (checked_at, month, service, locked_cost, source_cost, diff, diff_pct, status)
SELECT
  CURRENT_TIMESTAMP,
  COALESCE(l.month, s.usage_month),
  COALESCE(l.service, s.service),
  COALESCE(l.cost, 0),
  COALESCE(s.cost, 0),
  COALESCE(s.cost, 0) - COALESCE(l.cost, 0),
  CASE WHEN COALESCE(l.cost, 0) = 0 THEN NULL
       ELSE (COALESCE(s.cost, 0) - l.cost) / l.cost END,
  CASE WHEN ABS(COALESCE(s.cost, 0) - COALESCE(l.cost, 0)) <= (SELECT tolerance_abs FROM lock_config)
       THEN 'OK' ELSE 'DRIFT' END
FROM actuals_locked l
FULL OUTER JOIN (
  SELECT usage_month, service, SUM(cost) AS cost
  FROM billing_source_view
  WHERE usage_month IN (SELECT month FROM actuals_locked)   -- only months that have been sealed
  GROUP BY usage_month, service
) s
  ON l.month = s.usage_month AND l.service = s.service;


-- ----------------------------------------------------------------------------
-- PART 5. TELL SOMEONE: the drift found by the latest check
-- ----------------------------------------------------------------------------
-- Send this result to a shared channel or inbox, with a named reader.
-- It reads the latest check run, so it needs no date arithmetic.

SELECT month, service, locked_cost, source_cost, diff, diff_pct
FROM drift_log
WHERE status = 'DRIFT'
  AND checked_at = (SELECT MAX(checked_at) FROM drift_log)
ORDER BY ABS(diff) DESC;


-- ----------------------------------------------------------------------------
-- WHEN A SEALED MONTH DRIFTS
-- ----------------------------------------------------------------------------
-- Late billing data will show up as drift. Decide on purpose:
--   * accept it, if it is within the tolerance you set, or
--   * reseal as a NEW labelled version with a written reason (add a version column to actuals_locked).
-- Never edit a sealed row in place.
-- Seal from the raw export, not from your own derived tables, so the check does not depend on the
-- pipeline that built them.


-- ----------------------------------------------------------------------------
-- WHAT DIFFERS BY WAREHOUSE
-- ----------------------------------------------------------------------------
-- (Check your warehouse's documentation. This is a starting point, not a guarantee.)
--
-- First day of the month, for usage_month in the Part 1 view:
--   BigQuery                         DATE_TRUNC(usage_date, MONTH)
--   Snowflake                        DATE_TRUNC('month', usage_date)
--   PostgreSQL, Redshift             CAST(DATE_TRUNC('month', usage_date) AS DATE)
--   Databricks                       CAST(DATE_TRUNC('MONTH', usage_date) AS DATE)
--
-- Text column type in Part 2:
--   BigQuery                         STRING
--   All the others                   VARCHAR(255) works as written
--
-- Running Part 4 on a schedule (the part people forget):
--   BigQuery                         a scheduled query
--   Snowflake                        a task
--   Databricks                       a job or workflow
--   PostgreSQL                       pg_cron, or any external scheduler
--   Redshift                         a scheduled query in the query editor, or any external scheduler
--
-- Sending Part 5 to a person: use whatever your team already reads (email, chat webhook, ticket).
--
-- If your warehouse rejects FULL OUTER JOIN in Part 4, run the check as two statements instead:
-- one from the locked side with a LEFT JOIN, and one from the source side with a LEFT JOIN where
-- the locked side is NULL.
