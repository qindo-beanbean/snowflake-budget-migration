-- =====================================================
-- File: 03_usp_ReconcileIntercompanyBalances_SF.sql
-- Description: Intercompany Balance Reconciliation (Simplified)
-- Migrated from SQL Server to Snowflake
-- Version: Simplified - No INTERCOMPANYFLAG check
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

CREATE OR REPLACE PROCEDURE USP_RECONCILEINTERCOMPANYBALANCES_SF (
  BUDGETHEADERID          NUMBER,
  RECONCILIATIONDATE      DATE    DEFAULT NULL,
  TOLERANCEAMOUNT         NUMBER(19,4) DEFAULT 0.01,
  TOLERANCEPERCENT        NUMBER(5,4)  DEFAULT 0.001,
  AUTOCREATEADJUSTMENTS   BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
  RECONCILIATIONREPORT    VARIANT,
  UNRECONCILEDCOUNT       NUMBER,
  TOTALVARIANCEAMOUNT     NUMBER,
  RETURNCODE              NUMBER
)
LANGUAGE SQL
AS
$$
DECLARE
  EFFECTIVEDATE       DATE := COALESCE(:RECONCILIATIONDATE, CURRENT_DATE());
  RECONCILIATION_ID   STRING := UUID_STRING();
  
  RECONCILIATIONREPORT    VARIANT;
  UNRECONCILEDCOUNT       NUMBER := 0;
  TOTALVARIANCEAMOUNT     NUMBER := 0;
  RETURNCODE              NUMBER := 0;
  
  -- Validation variables
  BUDGET_EXISTS           NUMBER;
  UNRECONCILED_CNT        NUMBER;
  TOTAL_VAR_AMT           NUMBER;
  
  res RESULTSET;
BEGIN
  --------------------------------------------------------------------
  -- 1. Basic validation: Check if budget header exists
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO :BUDGET_EXISTS
  FROM BUDGETHEADER 
  WHERE BUDGETHEADERID = :BUDGETHEADERID;
  
  IF (:BUDGET_EXISTS = 0) THEN
    RECONCILIATIONREPORT := OBJECT_CONSTRUCT(
      'status', 'ERROR',
      'message', 'BudgetHeader not found: ' || :BUDGETHEADERID
    );
    UNRECONCILEDCOUNT   := 0;
    TOTALVARIANCEAMOUNT := 0;
    RETURNCODE := -1;
    res := (
      SELECT 
        :RECONCILIATIONREPORT AS RECONCILIATIONREPORT,
        :UNRECONCILEDCOUNT AS UNRECONCILEDCOUNT,
        :TOTALVARIANCEAMOUNT AS TOTALVARIANCEAMOUNT,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
  END IF;

  --------------------------------------------------------------------
  -- 2. Calculate entity pair variances (simplified version)
  --    Entity code = cost center code prefix before '-'
  --------------------------------------------------------------------
  DROP TABLE IF EXISTS ICP_PAIRS;
  CREATE TEMP TABLE ICP_PAIRS AS
  SELECT
    ENTITY1CODE,
    ENTITY2CODE,
    GLACCOUNTID,
    ENTITY1AMOUNT,
    ENTITY2AMOUNT,
    VARIANCE,
    VARIANCEPCT,
    CASE
      WHEN ABS(VARIANCE) <= :TOLERANCEAMOUNT THEN TRUE
      WHEN ABS(ENTITY1AMOUNT) > 0
           AND ABS(VARIANCE / ENTITY1AMOUNT) <= :TOLERANCEPERCENT
        THEN TRUE
      ELSE FALSE
    END AS ISWITHTOLERANCE
  FROM (
    SELECT
      SPLIT_PART(cc1.COSTCENTERCODE, '-', 1) AS ENTITY1CODE,
      COALESCE(SPLIT_PART(cc2.COSTCENTERCODE, '-', 1), 'UNKNOWN') AS ENTITY2CODE,
      bli1.GLACCOUNTID AS GLACCOUNTID,
      SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT) AS ENTITY1AMOUNT,
      -SUM(COALESCE(bli2.ORIGINALAMOUNT + bli2.ADJUSTEDAMOUNT, 0)) AS ENTITY2AMOUNT,
      SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT)
        + SUM(COALESCE(bli2.ORIGINALAMOUNT + bli2.ADJUSTEDAMOUNT, 0)) AS VARIANCE,
      CASE
        WHEN ABS(SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT)) > 0 THEN
          (SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT)
           + SUM(COALESCE(bli2.ORIGINALAMOUNT + bli2.ADJUSTEDAMOUNT, 0)))
          / ABS(SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT))
        ELSE NULL
      END AS VARIANCEPCT
    FROM BUDGETLINEITEM bli1
    JOIN GLACCOUNT gla1 ON bli1.GLACCOUNTID = gla1.GLACCOUNTID
    JOIN COSTCENTER cc1 ON bli1.COSTCENTERID = cc1.COSTCENTERID
    LEFT JOIN BUDGETLINEITEM bli2 ON bli2.BUDGETHEADERID = :BUDGETHEADERID
    LEFT JOIN COSTCENTER cc2 ON bli2.COSTCENTERID = cc2.COSTCENTERID
    WHERE bli1.BUDGETHEADERID = :BUDGETHEADERID
    GROUP BY
      SPLIT_PART(cc1.COSTCENTERCODE, '-', 1),
      SPLIT_PART(cc2.COSTCENTERCODE, '-', 1),
      bli1.GLACCOUNTID
    HAVING
      SUM(bli1.ORIGINALAMOUNT + bli1.ADJUSTEDAMOUNT) <> 0
      OR SUM(COALESCE(bli2.ORIGINALAMOUNT + bli2.ADJUSTEDAMOUNT, 0)) <> 0
  );

  --------------------------------------------------------------------
  -- 3. Mark status and calculate unreconciled variances
  --------------------------------------------------------------------
  DROP TABLE IF EXISTS ICP_PAIRS_STATUS;
  CREATE TEMP TABLE ICP_PAIRS_STATUS AS
  SELECT
    ROW_NUMBER() OVER (ORDER BY ABS(VARIANCE) DESC) AS PAIRID,
    *,
    CASE
      WHEN ISWITHTOLERANCE THEN 'RECONCILED'
      ELSE 'UNRECONCILED'
    END AS STATUS
  FROM ICP_PAIRS;

  -- Count unreconciled pairs and sum variances
  SELECT
    COUNT(CASE WHEN STATUS = 'UNRECONCILED' THEN 1 END),
    COALESCE(SUM(CASE WHEN STATUS = 'UNRECONCILED' THEN ABS(VARIANCE) ELSE 0 END), 0)
  INTO :UNRECONCILED_CNT, :TOTAL_VAR_AMT
  FROM ICP_PAIRS_STATUS;
  
  UNRECONCILEDCOUNT := UNRECONCILED_CNT;
  TOTALVARIANCEAMOUNT := TOTAL_VAR_AMT;

  --------------------------------------------------------------------
  -- 4. Build summary VARIANT report
  --------------------------------------------------------------------
  RECONCILIATIONREPORT := OBJECT_CONSTRUCT(
    'reconciliationId',  :RECONCILIATION_ID,
    'budgetHeaderId',    :BUDGETHEADERID,
    'effectiveDate',     :EFFECTIVEDATE,
    'toleranceAmount',   :TOLERANCEAMOUNT,
    'tolerancePercent',  :TOLERANCEPERCENT,
    'totalPairs',        (SELECT COUNT(*) FROM ICP_PAIRS_STATUS),
    'reconciledPairs',   (SELECT COUNT(CASE WHEN STATUS = 'RECONCILED' THEN 1 END) FROM ICP_PAIRS_STATUS),
    'unreconciledPairs', :UNRECONCILEDCOUNT,
    'totalVariance',     (SELECT COALESCE(SUM(ABS(VARIANCE)),0) FROM ICP_PAIRS_STATUS),
    'outOfToleranceVariance', :TOTALVARIANCEAMOUNT,
    'samplePairs',
      (SELECT ARRAY_AGG(
                OBJECT_CONSTRUCT(
                  'entity1', ENTITY1CODE,
                  'entity2', ENTITY2CODE,
                  'glAccountId', GLACCOUNTID,
                  'amount1', ENTITY1AMOUNT,
                  'amount2', ENTITY2AMOUNT,
                  'variance', VARIANCE,
                  'status', STATUS
                )
              ) 
       FROM (SELECT * FROM ICP_PAIRS_STATUS ORDER BY ABS(VARIANCE) DESC LIMIT 50)
      )
  );

  RETURNCODE := 0;
  res := (
    SELECT 
      :RECONCILIATIONREPORT AS RECONCILIATIONREPORT,
      :UNRECONCILEDCOUNT AS UNRECONCILEDCOUNT,
      :TOTALVARIANCEAMOUNT AS TOTALVARIANCEAMOUNT,
      :RETURNCODE AS RETURNCODE
  );
  RETURN TABLE(res);

EXCEPTION
  WHEN OTHER THEN
    RECONCILIATIONREPORT := OBJECT_CONSTRUCT(
      'status',  'ERROR',
      'message', SQLERRM,
      'sqlcode', SQLCODE
    );
    UNRECONCILEDCOUNT   := 0;
    TOTALVARIANCEAMOUNT := 0;
    RETURNCODE := -1;
    res := (
      SELECT 
        :RECONCILIATIONREPORT AS RECONCILIATIONREPORT,
        :UNRECONCILEDCOUNT AS UNRECONCILEDCOUNT,
        :TOTALVARIANCEAMOUNT AS TOTALVARIANCEAMOUNT,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
END;
$$;

-- Verify procedure was created successfully
SHOW PROCEDURES LIKE 'USP_RECONCILEINTERCOMPANYBALANCES_SF';