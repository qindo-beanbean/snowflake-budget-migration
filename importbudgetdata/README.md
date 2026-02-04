-- =====================================================
-- File: usp_BulkImportBudgetData_SF.sql
-- Description: Bulk Import Budget Data from Staging Table
-- Migrated from SQL Server to Snowflake
-- Version: 2.0 (Fixed UPDATE subquery issue)
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

CREATE OR REPLACE PROCEDURE USP_BULKIMPORTBUDGETDATA_SF (
  IMPORTSOURCE         STRING,          -- Currently only supports 'STAGING_TABLE'
  STAGINGTABLENAME     STRING,          -- e.g., 'BUDGETIMPORT_STAGE'
  TARGETBUDGETHEADERID NUMBER,
  VALIDATIONMODE       STRING DEFAULT 'STRICT',  -- 'STRICT' / 'LENIENT' / 'NONE'
  DUPLICATEHANDLING    STRING DEFAULT 'REJECT'   -- 'REJECT' / 'SKIP'
)
RETURNS TABLE (
  IMPORTRESULTS        VARIANT,
  ROWSIMPORTED         NUMBER,
  ROWSREJECTED         NUMBER,
  RETURNCODE           NUMBER
)
LANGUAGE SQL
AS
$$
DECLARE
  STARTTIME           TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
  TOTALROWS           NUMBER := 0;
  VALIDROWS           NUMBER := 0;
  INVALIDROWS         NUMBER := 0;
  ROWSIMPORTED        NUMBER := 0;
  ROWSREJECTED        NUMBER := 0;
  IMPORTRESULTS       VARIANT;
  RETURNCODE          NUMBER := 0;
  
  -- Validation variables
  SOURCE_CHECK        STRING;
  DUPLICATE_CHECK     STRING;
  VALIDATION_CHECK    STRING;
  
  res RESULTSET;
BEGIN
  --------------------------------------------------------------------
  -- 0. Only supports STAGING_TABLE
  --------------------------------------------------------------------
  SOURCE_CHECK := UPPER(:IMPORTSOURCE);
  
  IF (SOURCE_CHECK <> 'STAGING_TABLE') THEN
    IMPORTRESULTS := OBJECT_CONSTRUCT(
      'error', 'Only STAGING_TABLE source is supported in Snowflake version'
    );
    ROWSIMPORTED := 0;
    ROWSREJECTED := 0;
    RETURNCODE := -1;
    res := (
      SELECT 
        :IMPORTRESULTS AS IMPORTRESULTS,
        :ROWSIMPORTED AS ROWSIMPORTED,
        :ROWSREJECTED AS ROWSREJECTED,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
  END IF;

  --------------------------------------------------------------------
  -- 1. Copy staging data to temp table with validation columns
  --    Use LEFT JOINs to lookup IDs directly (avoids UPDATE subquery issue)
  --------------------------------------------------------------------
  -- Drop temp table if exists from previous run
  EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS IMPORTSTAGING_TEMP';
  
  -- Create temp table with lookups already done via JOINs
  EXECUTE IMMEDIATE '
    CREATE TEMP TABLE IMPORTSTAGING_TEMP AS
    SELECT
      ROW_NUMBER() OVER (ORDER BY 1)      AS ROWID,
      gla.GLACCOUNTID                     AS GLACCOUNTID,
      s.ACCOUNTNUMBER,
      cc.COSTCENTERID                     AS COSTCENTERID,
      s.COSTCENTERCODE,
      fp.FISCALPERIODID                   AS FISCALPERIODID,
      s.FISCALYEAR,
      s.FISCALMONTH,
      s.ORIGINALAMOUNT,
      s.ADJUSTEDAMOUNT,
      s.SPREADMETHODCODE,
      s.NOTES,
      TRUE::BOOLEAN                       AS ISVALID,
      NULL::STRING                        AS VALIDATIONERRORS
    FROM ' || :STAGINGTABLENAME || ' s
    LEFT JOIN GLACCOUNT gla ON s.ACCOUNTNUMBER = gla.ACCOUNTNUMBER
    LEFT JOIN COSTCENTER cc ON s.COSTCENTERCODE = cc.COSTCENTERCODE
    LEFT JOIN FISCALPERIOD fp ON s.FISCALYEAR = fp.FISCALYEAR AND s.FISCALMONTH = fp.FISCALMONTH
  ';

  SELECT COUNT(*) INTO :TOTALROWS FROM IMPORTSTAGING_TEMP;

  --------------------------------------------------------------------
  -- 2. Basic validation
  --------------------------------------------------------------------
  VALIDATION_CHECK := UPPER(:VALIDATIONMODE);
  
  IF (VALIDATION_CHECK <> 'NONE') THEN

    -- Missing Account
    UPDATE IMPORTSTAGING_TEMP
    SET ISVALID = FALSE,
        VALIDATIONERRORS = COALESCE(VALIDATIONERRORS || '; ', '') || 'MISSING_ACCOUNT'
    WHERE GLACCOUNTID IS NULL;

    -- Missing Cost Center
    UPDATE IMPORTSTAGING_TEMP
    SET ISVALID = FALSE,
        VALIDATIONERRORS = COALESCE(VALIDATIONERRORS || '; ', '') || 'MISSING_COSTCENTER'
    WHERE COSTCENTERID IS NULL;

    -- Missing Period
    UPDATE IMPORTSTAGING_TEMP
    SET ISVALID = FALSE,
        VALIDATIONERRORS = COALESCE(VALIDATIONERRORS || '; ', '') || 'MISSING_PERIOD'
    WHERE FISCALPERIODID IS NULL;

    -- Invalid Amount
    UPDATE IMPORTSTAGING_TEMP
    SET ISVALID = FALSE,
        VALIDATIONERRORS = COALESCE(VALIDATIONERRORS || '; ', '') || 'INVALID_AMOUNT'
    WHERE ORIGINALAMOUNT IS NULL;

    -- Closed Period
    UPDATE IMPORTSTAGING_TEMP stg
    SET ISVALID = FALSE,
        VALIDATIONERRORS = COALESCE(stg.VALIDATIONERRORS || '; ', '') || 'CLOSED_PERIOD'
    WHERE EXISTS (
      SELECT 1
      FROM FISCALPERIOD fp
      WHERE fp.FISCALPERIODID = stg.FISCALPERIODID
        AND fp.ISCLOSED = TRUE
    );

    -- Already Exists (REJECT mode only)
    DUPLICATE_CHECK := UPPER(:DUPLICATEHANDLING);
    
    IF (DUPLICATE_CHECK = 'REJECT') THEN
      UPDATE IMPORTSTAGING_TEMP stg
      SET ISVALID = FALSE,
          VALIDATIONERRORS = COALESCE(stg.VALIDATIONERRORS || '; ', '') || 'ALREADY_EXISTS'
      WHERE EXISTS (
        SELECT 1
        FROM BUDGETLINEITEM bli
        WHERE bli.BUDGETHEADERID = :TARGETBUDGETHEADERID
          AND bli.GLACCOUNTID    = stg.GLACCOUNTID
          AND bli.COSTCENTERID   = stg.COSTCENTERID
          AND bli.FISCALPERIODID = stg.FISCALPERIODID
      );
    END IF;
  END IF;

  -- Count valid and invalid rows
  SELECT
    SUM(CASE WHEN ISVALID THEN 1 ELSE 0 END),
    SUM(CASE WHEN NOT ISVALID THEN 1 ELSE 0 END)
  INTO :VALIDROWS, :INVALIDROWS
  FROM IMPORTSTAGING_TEMP;

  --------------------------------------------------------------------
  -- 3. Insert valid records
  --------------------------------------------------------------------
  IF (:VALIDROWS > 0) THEN
    DUPLICATE_CHECK := UPPER(:DUPLICATEHANDLING);
    
    IF (DUPLICATE_CHECK = 'SKIP') THEN
      -- Skip duplicates
      INSERT INTO BUDGETLINEITEM (
        BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
        ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
        SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
        LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
      )
      SELECT
        :TARGETBUDGETHEADERID,
        stg.GLACCOUNTID,
        stg.COSTCENTERID,
        stg.FISCALPERIODID,
        stg.ORIGINALAMOUNT,
        COALESCE(stg.ADJUSTEDAMOUNT, 0),
        stg.SPREADMETHODCODE,
        'BULK_IMPORT',
        'STAGING:' || :STAGINGTABLENAME,
        FALSE,
        0,
        CURRENT_TIMESTAMP()
      FROM IMPORTSTAGING_TEMP stg
      WHERE stg.ISVALID = TRUE
        AND NOT EXISTS (
          SELECT 1 FROM BUDGETLINEITEM bli
          WHERE bli.BUDGETHEADERID = :TARGETBUDGETHEADERID
            AND bli.GLACCOUNTID    = stg.GLACCOUNTID
            AND bli.COSTCENTERID   = stg.COSTCENTERID
            AND bli.FISCALPERIODID = stg.FISCALPERIODID
        );
    ELSE
      -- Insert all valid rows (REJECT mode)
      INSERT INTO BUDGETLINEITEM (
        BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
        ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
        SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
        LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
      )
      SELECT
        :TARGETBUDGETHEADERID,
        GLACCOUNTID,
        COSTCENTERID,
        FISCALPERIODID,
        ORIGINALAMOUNT,
        COALESCE(ADJUSTEDAMOUNT, 0),
        SPREADMETHODCODE,
        'BULK_IMPORT',
        'STAGING:' || :STAGINGTABLENAME,
        FALSE,
        0,
        CURRENT_TIMESTAMP()
      FROM IMPORTSTAGING_TEMP
      WHERE ISVALID = TRUE;
    END IF;

    ROWSIMPORTED := SQLROWCOUNT;
  ELSE
    ROWSIMPORTED := 0;
  END IF;

  ROWSREJECTED := INVALIDROWS;

  --------------------------------------------------------------------
  -- 4. Build result summary (VARIANT)
  --------------------------------------------------------------------
  IMPORTRESULTS := OBJECT_CONSTRUCT(
    'ImportSource', :IMPORTSOURCE,
    'StagingTable', :STAGINGTABLENAME,
    'TargetBudgetHeaderId', :TARGETBUDGETHEADERID,
    'DurationMs', DATEDIFF('millisecond', :STARTTIME, CURRENT_TIMESTAMP()),
    'TotalRows', :TOTALROWS,
    'ValidRows', :VALIDROWS,
    'InvalidRows', :INVALIDROWS,
    'RowsImported', :ROWSIMPORTED,
    'RowsRejected', :ROWSREJECTED
  );

  -- Return success
  res := (
    SELECT 
      :IMPORTRESULTS AS IMPORTRESULTS,
      :ROWSIMPORTED AS ROWSIMPORTED,
      :ROWSREJECTED AS ROWSREJECTED,
      :RETURNCODE AS RETURNCODE
  );
  RETURN TABLE(res);

EXCEPTION
  WHEN OTHER THEN
    IMPORTRESULTS := OBJECT_CONSTRUCT(
      'error', SQLERRM,
      'sqlcode', SQLCODE
    );
    ROWSIMPORTED := 0;
    ROWSREJECTED := :TOTALROWS;
    RETURNCODE := -1;
    res := (
      SELECT 
        :IMPORTRESULTS AS IMPORTRESULTS,
        :ROWSIMPORTED AS ROWSIMPORTED,
        :ROWSREJECTED AS ROWSREJECTED,
        :RETURNCODE AS RETURNCODE
    );
    RETURN TABLE(res);
END;
$$;

-- Verify procedure was created successfully
SHOW PROCEDURES LIKE 'USP_BULKIMPORTBUDGETDATA_SF';