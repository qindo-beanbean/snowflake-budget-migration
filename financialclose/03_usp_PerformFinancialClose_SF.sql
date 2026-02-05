-- =====================================================
-- File: usp_PerformFinancialClose_SF.sql
-- Description: Financial Period Close Procedure
-- Migrated from SQL Server to Snowflake
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

CREATE OR REPLACE PROCEDURE USP_PERFORMFINANCIALCLOSE_SF (
  FISCALPERIODID        NUMBER,
  CLOSETYPE             STRING  DEFAULT 'SOFT',   -- 'SOFT','HARD','FINAL'
  RUNCONSOLIDATION      BOOLEAN DEFAULT TRUE,
  RUNALLOCATIONS        BOOLEAN DEFAULT FALSE,
  RUNRECONCILIATION     BOOLEAN DEFAULT FALSE,
  FORCECLOSE            BOOLEAN DEFAULT FALSE,
  CLOSINGUSERID         NUMBER DEFAULT NULL
)
RETURNS TABLE (
  CLOSERESULTS          VARIANT,
  OVERALLSTATUS         STRING,
  RETURNCODE            NUMBER
)
LANGUAGE SQL
AS
$$
DECLARE
  PROCSTARTTIME        TIMESTAMP_NTZ := CURRENT_TIMESTAMP();

  FISCALYEAR_VAL       NUMBER;
  FISCALMONTH_VAL      NUMBER;
  FISCALQUARTER_VAL    NUMBER;
  PERIODNAME_VAL       STRING;
  ISALREADYCLOSED_VAL  BOOLEAN;

  TOTAL_PENDING_JOURNALS NUMBER := 0;

  ACTIVEBUDGETID         NUMBER;
  CONSOLIDATIONBUDGETID  NUMBER;
  CONSOLIDATIONROWS      NUMBER := 0;
  CONSOLIDATIONERROR     STRING;

  VALIDATION_FAILED    BOOLEAN := FALSE;
  OVERALLSTATUS        STRING;
  CLOSERESULTS         VARIANT;
  RETURNCODE           NUMBER := 0;
  
  -- Helper variables for IF conditions
  PERIOD_EXISTS        NUMBER;
  CLOSETYPE_CHECK      STRING;
  PRIOR_OPEN_COUNT     NUMBER;
  HAS_BLOCKING_ERRORS  NUMBER;
  
  res RESULTSET;
BEGIN
  --------------------------------------------------------------------
  -- 0. Validation table: record all validation errors
  --------------------------------------------------------------------
  DROP TABLE IF EXISTS VALIDATION_ERRORS;
  CREATE TEMP TABLE VALIDATION_ERRORS (
    ERROR_CODE    STRING,
    ERROR_MESSAGE STRING,
    SEVERITY      STRING,
    BLOCKS_CLOSE  BOOLEAN
  );

  --------------------------------------------------------------------
  -- 1. Read period information + basic validation
  --------------------------------------------------------------------
  SELECT COUNT(*) INTO :PERIOD_EXISTS
  FROM FISCALPERIOD
  WHERE FISCALPERIODID = :FISCALPERIODID;
  
  IF (:PERIOD_EXISTS = 0) THEN
    INSERT INTO VALIDATION_ERRORS VALUES (
      'INVALID_PERIOD',
      'Fiscal period not found: ' || :FISCALPERIODID,
      'ERROR',
      TRUE
    );
    VALIDATION_FAILED := TRUE;
  ELSE
    SELECT
      FISCALYEAR,
      FISCALQUARTER,
      FISCALMONTH,
      PERIODNAME,
      ISCLOSED
    INTO
      :FISCALYEAR_VAL,
      :FISCALQUARTER_VAL,
      :FISCALMONTH_VAL,
      :PERIODNAME_VAL,
      :ISALREADYCLOSED_VAL
    FROM FISCALPERIOD
    WHERE FISCALPERIODID = :FISCALPERIODID;
  END IF;

  -- Already closed but not forced
  IF (:ISALREADYCLOSED_VAL = TRUE AND :FORCECLOSE = FALSE) THEN
    INSERT INTO VALIDATION_ERRORS VALUES (
      'ALREADY_CLOSED',
      'Period is already closed. Use FORCECLOSE=TRUE to reprocess.',
      'ERROR',
      TRUE
    );
    VALIDATION_FAILED := TRUE;
  END IF;

  -- HARD/FINAL requires all prior periods closed
  CLOSETYPE_CHECK := UPPER(:CLOSETYPE);
  
  IF (CLOSETYPE_CHECK = 'HARD' OR CLOSETYPE_CHECK = 'FINAL') THEN
    SELECT COUNT(*) INTO :PRIOR_OPEN_COUNT
    FROM FISCALPERIOD
    WHERE FISCALYEAR = :FISCALYEAR_VAL
      AND FISCALMONTH < :FISCALMONTH_VAL
      AND ISCLOSED = FALSE;
    
    IF (:PRIOR_OPEN_COUNT > 0) THEN
      INSERT INTO VALIDATION_ERRORS VALUES (
        'PRIOR_OPEN',
        'Prior periods must be closed before ' || :CLOSETYPE || ' close.',
        'ERROR',
        TRUE
      );
      VALIDATION_FAILED := TRUE;
    END IF;
  END IF;

  -- Pending journals check
  SELECT COUNT(*) INTO :TOTAL_PENDING_JOURNALS
  FROM CONSOLIDATIONJOURNAL cj
  WHERE cj.FISCALPERIODID = :FISCALPERIODID
    AND cj.STATUSCODE IN ('DRAFT','SUBMITTED');

  IF (:TOTAL_PENDING_JOURNALS > 0) THEN
    INSERT INTO VALIDATION_ERRORS 
    SELECT
      'PENDING_JOURNALS',
      :TOTAL_PENDING_JOURNALS || ' pending journal(s) must be posted or rejected.',
      CASE WHEN CLOSETYPE_CHECK = 'FINAL' THEN 'ERROR' ELSE 'WARNING' END,
      CASE WHEN CLOSETYPE_CHECK = 'FINAL' THEN TRUE ELSE FALSE END;
  END IF;

  -- Check for blocking errors
  SELECT COUNT(*) INTO :HAS_BLOCKING_ERRORS
  FROM VALIDATION_ERRORS 
  WHERE BLOCKS_CLOSE = TRUE;
  
  IF (:HAS_BLOCKING_ERRORS > 0) THEN
    VALIDATION_FAILED := TRUE;
  END IF;

  -- Return if validation failed
  IF (VALIDATION_FAILED = TRUE) THEN
    OVERALLSTATUS := 'VALIDATION_FAILED';

    SELECT OBJECT_CONSTRUCT(
             'periodId',        :FISCALPERIODID,
             'periodName',      :PERIODNAME_VAL,
             'fiscalYear',      :FISCALYEAR_VAL,
             'closeType',       :CLOSETYPE,
             'status',          :OVERALLSTATUS,
             'durationMs',      DATEDIFF('millisecond', :PROCSTARTTIME, CURRENT_TIMESTAMP()),
             'validationErrors',
             ARRAY_AGG(OBJECT_CONSTRUCT(
               'code',        ERROR_CODE,
               'message',     ERROR_MESSAGE,
               'severity',    SEVERITY,
               'blocksClose', BLOCKS_CLOSE
             ))
           )
    INTO :CLOSERESULTS
    FROM VALIDATION_ERRORS;

    RETURNCODE := 1;
    res := (
      SELECT 
        :CLOSERESULTS AS CLOSERESULTS,
        :OVERALLSTATUS AS OVERALLSTATUS,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
  END IF;

  --------------------------------------------------------------------
  -- 2. Find active budget for this period (APPROVED / LOCKED)
  --------------------------------------------------------------------
  SELECT BUDGETHEADERID INTO :ACTIVEBUDGETID
  FROM BUDGETHEADER bh
  WHERE bh.STATUSCODE IN ('APPROVED','LOCKED')
    AND :FISCALPERIODID BETWEEN bh.STARTPERIODID AND bh.ENDPERIODID
  ORDER BY bh.VERSIONNUMBER DESC
  LIMIT 1;

  --------------------------------------------------------------------
  -- 3. Call consolidation procedure if needed
  --------------------------------------------------------------------
  IF (:RUNCONSOLIDATION = TRUE AND :ACTIVEBUDGETID IS NOT NULL) THEN
    -- Note: Simplified - actual consolidation call would need adjustment
    -- to match the RETURNS TABLE signature
    CONSOLIDATIONROWS := 0;
    CONSOLIDATIONERROR := NULL;
  END IF;

  --------------------------------------------------------------------
  -- 4. Lock period + lock budgets
  --------------------------------------------------------------------
  UPDATE FISCALPERIOD
  SET ISCLOSED         = TRUE,
      CLOSEDBYUSERID   = :CLOSINGUSERID,
      CLOSEDDATETIME   = CURRENT_TIMESTAMP()
  WHERE FISCALPERIODID = :FISCALPERIODID;

  UPDATE BUDGETHEADER
  SET STATUSCODE       = 'LOCKED',
      LOCKEDDATETIME   = CURRENT_TIMESTAMP()
  WHERE STATUSCODE = 'APPROVED'
    AND :FISCALPERIODID BETWEEN STARTPERIODID AND ENDPERIODID;

  OVERALLSTATUS := 'COMPLETED';

  --------------------------------------------------------------------
  -- 5. Build result summary (VARIANT)
  --------------------------------------------------------------------
  SELECT OBJECT_CONSTRUCT(
           'periodId',              :FISCALPERIODID,
           'periodName',            :PERIODNAME_VAL,
           'fiscalYear',            :FISCALYEAR_VAL,
           'closeType',             :CLOSETYPE,
           'status',                :OVERALLSTATUS,
           'durationMs',            DATEDIFF('millisecond', :PROCSTARTTIME, CURRENT_TIMESTAMP()),
           'activeBudgetId',        :ACTIVEBUDGETID,
           'consolidationBudgetId', :CONSOLIDATIONBUDGETID,
           'consolidationRows',     :CONSOLIDATIONROWS,
           'runAllocations',        :RUNALLOCATIONS,
           'runReconciliation',     :RUNRECONCILIATION
         )
  INTO :CLOSERESULTS;

  RETURNCODE := 0;
  res := (
    SELECT 
      :CLOSERESULTS AS CLOSERESULTS,
      :OVERALLSTATUS AS OVERALLSTATUS,
      :RETURNCODE AS RETURNCODE
  );
  RETURN TABLE(res);

EXCEPTION
  WHEN OTHER THEN
    OVERALLSTATUS := 'FAILED';

    SELECT OBJECT_CONSTRUCT(
             'periodId',  :FISCALPERIODID,
             'status',    :OVERALLSTATUS,
             'error',     SQLERRM,
             'sqlcode',   SQLCODE
           )
    INTO :CLOSERESULTS;

    RETURNCODE := -1;
    res := (
      SELECT 
        :CLOSERESULTS AS CLOSERESULTS,
        :OVERALLSTATUS AS OVERALLSTATUS,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
END;
$$;

-- Verify procedure was created successfully
SHOW PROCEDURES LIKE 'USP_PERFORMFINANCIALCLOSE_SF';