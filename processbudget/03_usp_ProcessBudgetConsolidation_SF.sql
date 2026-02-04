-- =====================================================
-- File: usp_ProcessBudgetConsolidation_SF.sql
-- Description: Budget Consolidation Procedure (SQL Server to Snowflake Migration)
-- Original Author: Snowflake Engineering Challenge
-- Migrated By: Qin
-- Migration Date: 2025-02-04
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

CREATE OR REPLACE PROCEDURE USP_PROCESSBUDGETCONSOLIDATION_SF (
  SOURCEBUDGETHEADERID   NUMBER,
  CONSOLIDATIONTYPE      STRING   DEFAULT 'FULL',
  INCLUDEELIMINATIONS    BOOLEAN  DEFAULT TRUE,
  RECALCULATEALLOCATIONS BOOLEAN  DEFAULT TRUE,
  PROCESSINGOPTIONS      VARIANT  DEFAULT NULL,
  USERID                 NUMBER   DEFAULT NULL,
  DEBUGMODE              BOOLEAN  DEFAULT FALSE
)
RETURNS TABLE (
  TARGETBUDGETHEADERID   NUMBER,
  ROWSPROCESSED          NUMBER,
  ERRORMESSAGE           STRING,
  RETURNCODE             NUMBER
)
LANGUAGE SQL
AS
$$
DECLARE
  PROCSTARTTIME       TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
  RETURNCODE          NUMBER        := 0;
  TOTALROWSPROCESSED  NUMBER        := 0;
  TARGETBUDGETHEADERID NUMBER       := NULL;
  ERRORMESSAGE        STRING        := NULL;

  SRC_BUDGETCODE      STRING;
  SRC_BUDGETNAME      STRING;
  SRC_BUDGETTYPE      STRING;
  SRC_SCENARIOTYPE    STRING;
  SRC_FISCALYEAR      NUMBER;
  SRC_STARTPERIODID   NUMBER;
  SRC_ENDPERIODID     NUMBER;
  
  SOURCE_EXISTS       NUMBER;
  INVALID_STATUS      NUMBER;
  
  res RESULTSET;
BEGIN
  ----------------------------------------------------------------------
  -- 1. Parameter Validation: Check if source budget exists
  ----------------------------------------------------------------------
  SELECT COUNT(*) INTO :SOURCE_EXISTS
  FROM BUDGETHEADER
  WHERE BUDGETHEADERID = :SOURCEBUDGETHEADERID;
  
  IF (:SOURCE_EXISTS = 0) THEN
    ERRORMESSAGE := 'Source budget header not found: ' || :SOURCEBUDGETHEADERID;
    RETURNCODE := -1;
    res := (
      SELECT 
        :TARGETBUDGETHEADERID AS TARGETBUDGETHEADERID,
        :TOTALROWSPROCESSED AS ROWSPROCESSED,
        :ERRORMESSAGE AS ERRORMESSAGE,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
  END IF;

  ----------------------------------------------------------------------
  -- 2. Status Validation: Must be APPROVED or LOCKED
  ----------------------------------------------------------------------
  SELECT COUNT(*) INTO :INVALID_STATUS
  FROM BUDGETHEADER
  WHERE BUDGETHEADERID = :SOURCEBUDGETHEADERID
    AND STATUSCODE NOT IN ('APPROVED', 'LOCKED');
  
  IF (:INVALID_STATUS > 0) THEN
    ERRORMESSAGE := 'Source budget must be in APPROVED or LOCKED status for consolidation';
    RETURNCODE := -2;
    res := (
      SELECT 
        :TARGETBUDGETHEADERID AS TARGETBUDGETHEADERID,
        :TOTALROWSPROCESSED AS ROWSPROCESSED,
        :ERRORMESSAGE AS ERRORMESSAGE,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
  END IF;

  ----------------------------------------------------------------------
  -- 3. Read Source Budget Header Information
  ----------------------------------------------------------------------
  SELECT
    BUDGETCODE,
    BUDGETNAME,
    BUDGETTYPE,
    SCENARIOTYPE,
    FISCALYEAR,
    STARTPERIODID,
    ENDPERIODID
  INTO
    :SRC_BUDGETCODE,
    :SRC_BUDGETNAME,
    :SRC_BUDGETTYPE,
    :SRC_SCENARIOTYPE,
    :SRC_FISCALYEAR,
    :SRC_STARTPERIODID,
    :SRC_ENDPERIODID
  FROM BUDGETHEADER
  WHERE BUDGETHEADERID = :SOURCEBUDGETHEADERID;

  ----------------------------------------------------------------------
  -- 4. Create Target BudgetHeader
  ----------------------------------------------------------------------
  INSERT INTO BUDGETHEADER (
    BUDGETCODE,
    BUDGETNAME,
    BUDGETTYPE,
    SCENARIOTYPE,
    FISCALYEAR,
    STARTPERIODID,
    ENDPERIODID,
    BASEBUDGETHEADERID,
    STATUSCODE,
    VERSIONNUMBER,
    EXTENDEDPROPERTIES
  )
  SELECT
    :SRC_BUDGETCODE || '_CONSOL_' || TO_VARCHAR(CURRENT_DATE(), 'YYYYMMDD'),
    :SRC_BUDGETNAME || ' - Consolidated',
    'CONSOLIDATED',
    :SRC_SCENARIOTYPE,
    :SRC_FISCALYEAR,
    :SRC_STARTPERIODID,
    :SRC_ENDPERIODID,
    :SOURCEBUDGETHEADERID,
    'DRAFT',
    1,
    OBJECT_CONSTRUCT(
      'ConsolidationRunTime', TO_VARCHAR(:PROCSTARTTIME),
      'SourceBudgetHeaderId', :SOURCEBUDGETHEADERID,
      'ConsolidationType', :CONSOLIDATIONTYPE
    );

  SELECT MAX(BUDGETHEADERID) INTO :TARGETBUDGETHEADERID
  FROM BUDGETHEADER
  WHERE BUDGETCODE LIKE :SRC_BUDGETCODE || '_CONSOL_%';

  ----------------------------------------------------------------------
  -- 5. Clear Existing Target Budget Details (Idempotent)
  ----------------------------------------------------------------------
  DELETE FROM BUDGETLINEITEM
  WHERE BUDGETHEADERID = :TARGETBUDGETHEADERID;

  ----------------------------------------------------------------------
  -- 6. Consolidate and Insert from Source Budget
  --    Aggregate by: Account + Cost Center + Period
  ----------------------------------------------------------------------
  INSERT INTO BUDGETLINEITEM (
    BUDGETHEADERID,
    GLACCOUNTID,
    COSTCENTERID,
    FISCALPERIODID,
    ORIGINALAMOUNT,
    ADJUSTEDAMOUNT,
    SPREADMETHODCODE,
    SOURCESYSTEM,
    SOURCEREFERENCE,
    ISALLOCATED,
    LASTMODIFIEDBYUSERID,
    LASTMODIFIEDDATETIME
  )
  SELECT
    :TARGETBUDGETHEADERID                                            AS BUDGETHEADERID,
    bli.GLACCOUNTID,
    bli.COSTCENTERID,
    bli.FISCALPERIODID,
    SUM(bli.ORIGINALAMOUNT + bli.ADJUSTEDAMOUNT)                     AS ORIGINALAMOUNT,
    0                                                                 AS ADJUSTEDAMOUNT,
    'CONSOL'                                                          AS SPREADMETHODCODE,
    'CONSOLIDATION_PROC'                                              AS SOURCESYSTEM,
    'SRC_' || :SOURCEBUDGETHEADERID::STRING                           AS SOURCEREFERENCE,
    FALSE                                                             AS ISALLOCATED,
    :USERID,
    CURRENT_TIMESTAMP()
  FROM BUDGETLINEITEM bli
  WHERE bli.BUDGETHEADERID = :SOURCEBUDGETHEADERID
  GROUP BY
    bli.GLACCOUNTID,
    bli.COSTCENTERID,
    bli.FISCALPERIODID;

  TOTALROWSPROCESSED := SQLROWCOUNT;

  ----------------------------------------------------------------------
  -- 7. Return Success Result
  ----------------------------------------------------------------------
  res := (
    SELECT 
      :TARGETBUDGETHEADERID AS TARGETBUDGETHEADERID,
      :TOTALROWSPROCESSED AS ROWSPROCESSED,
      :ERRORMESSAGE AS ERRORMESSAGE,
      :RETURNCODE AS RETURNCODE
  );
  RETURN TABLE(res);

EXCEPTION
  WHEN OTHER THEN
    ERRORMESSAGE := 'Error: SQLCODE=' || SQLCODE || ', SQLERRM=' || SQLERRM;
    RETURNCODE := -999;
    res := (
      SELECT 
        :TARGETBUDGETHEADERID AS TARGETBUDGETHEADERID,
        :TOTALROWSPROCESSED AS ROWSPROCESSED,
        :ERRORMESSAGE AS ERRORMESSAGE,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
END;
$$;

-- Verify procedure was created successfully
SHOW PROCEDURES LIKE 'USP_PROCESSBUDGETCONSOLIDATION_SF';
