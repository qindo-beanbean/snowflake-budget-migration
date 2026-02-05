-- =====================================================
-- File: 04_test_financial_close_simple.sql
-- Description: Simple test for Financial Close procedure
-- Prerequisite: USP_PERFORMFINANCIALCLOSE_SF must exist
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- Setup Test Environment
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  SETUP TEST ENVIRONMENT' AS INFO;
SELECT '========================================' AS INFO;

-- Create required table
DROP TABLE IF EXISTS CONSOLIDATIONJOURNAL;
CREATE TABLE CONSOLIDATIONJOURNAL (
  CONSOLIDATIONJOURNALID  NUMBER IDENTITY(1,1) PRIMARY KEY,
  FISCALPERIODID          NUMBER NOT NULL,
  JOURNALCODE             STRING,
  DESCRIPTION             STRING,
  STATUSCODE              STRING NOT NULL,
  AMOUNT                  NUMBER(18,2),
  CREATEDDATE             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Add columns if missing
ALTER TABLE FISCALPERIOD ADD COLUMN IF NOT EXISTS CLOSEDBYUSERID NUMBER;
ALTER TABLE FISCALPERIOD ADD COLUMN IF NOT EXISTS CLOSEDDATETIME TIMESTAMP_NTZ;
ALTER TABLE BUDGETHEADER ADD COLUMN IF NOT EXISTS LOCKEDDATETIME TIMESTAMP_NTZ;

-- Create test period
INSERT INTO FISCALPERIOD (
  FISCALYEAR, FISCALQUARTER, FISCALMONTH,
  PERIODNAME, PERIODSTARTDATE, PERIODENDDATE, ISCLOSED
)
SELECT 2024, 1, 1, '2024-01', '2024-01-01', '2024-01-31', FALSE
WHERE NOT EXISTS (SELECT 1 FROM FISCALPERIOD WHERE PERIODNAME = '2024-01');

SET PERIOD_ID = (SELECT FISCALPERIODID FROM FISCALPERIOD WHERE PERIODNAME = '2024-01');

SELECT 'Test Period ID: ' || $PERIOD_ID AS INFO;

-- Create test budget
INSERT INTO BUDGETHEADER (
  BUDGETCODE, BUDGETNAME, BUDGETTYPE, SCENARIOTYPE,
  FISCALYEAR, STARTPERIODID, ENDPERIODID,
  BASEBUDGETHEADERID, STATUSCODE, VERSIONNUMBER
)
SELECT
  'BUD_CLOSE_TEST',
  'Close Test Budget',
  'OPERATIONAL',
  'BASELINE',
  2024,
  $PERIOD_ID,
  $PERIOD_ID,
  NULL,
  'APPROVED',
  1
WHERE NOT EXISTS (SELECT 1 FROM BUDGETHEADER WHERE BUDGETCODE = 'BUD_CLOSE_TEST');

SELECT 'Setup Complete' AS STATUS;

-- =====================================================
-- TEST 1: Successful Close
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 1: SUCCESSFUL CLOSE' AS INFO;
SELECT '========================================' AS INFO;

-- Reset period to open
UPDATE FISCALPERIOD 
SET ISCLOSED = FALSE, CLOSEDBYUSERID = NULL, CLOSEDDATETIME = NULL
WHERE FISCALPERIODID = $PERIOD_ID;

-- Clean journals
DELETE FROM CONSOLIDATIONJOURNAL WHERE FISCALPERIODID = $PERIOD_ID;

-- Execute close
CALL USP_PERFORMFINANCIALCLOSE_SF(
  $PERIOD_ID,
  'SOFT',
  FALSE,
  FALSE,
  FALSE,
  FALSE,
  100
);

-- Verify
SELECT 
  'Result:' AS INFO,
  CASE WHEN ISCLOSED THEN '✓ Period Closed' ELSE '✗ Period Still Open' END AS STATUS,
  CLOSEDBYUSERID AS CLOSED_BY
FROM FISCALPERIOD
WHERE FISCALPERIODID = $PERIOD_ID;

-- Expected: Period Closed ✓

-- =====================================================
-- TEST 2: Already Closed Error
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 2: ALREADY CLOSED ERROR' AS INFO;
SELECT '========================================' AS INFO;

-- Try to close again
CALL USP_PERFORMFINANCIALCLOSE_SF(
  $PERIOD_ID,
  'SOFT',
  FALSE,
  FALSE,
  FALSE,
  FALSE,
  100
);

-- Expected: Should return VALIDATION_FAILED with ALREADY_CLOSED error

-- =====================================================
-- TEST 3: Force Re-close
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 3: FORCE RE-CLOSE' AS INFO;
SELECT '========================================' AS INFO;

-- Re-close with force
CALL USP_PERFORMFINANCIALCLOSE_SF(
  $PERIOD_ID,
  'SOFT',
  FALSE,
  FALSE,
  FALSE,
  TRUE,   -- FORCECLOSE = TRUE
  200     -- Different user
);

-- Verify user changed
SELECT 
  'Result:' AS INFO,
  CASE WHEN CLOSEDBYUSERID = 200 THEN '✓ User Updated' ELSE '✗ User Not Updated' END AS STATUS,
  CLOSEDBYUSERID AS CLOSED_BY
FROM FISCALPERIOD
WHERE FISCALPERIODID = $PERIOD_ID;

-- Expected: User Updated to 200 ✓

-- =====================================================
-- TEST 4: Invalid Period
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 4: INVALID PERIOD' AS INFO;
SELECT '========================================' AS INFO;

-- Try with invalid ID
CALL USP_PERFORMFINANCIALCLOSE_SF(
  99999,
  'SOFT',
  FALSE,
  FALSE,
  FALSE,
  FALSE,
  100
);

-- Expected: Should return VALIDATION_FAILED with INVALID_PERIOD error

-- =====================================================
-- Summary
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST SUMMARY' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  PERIODNAME,
  ISCLOSED,
  CLOSEDBYUSERID,
  CLOSEDDATETIME
FROM FISCALPERIOD
WHERE PERIODNAME = '2024-01';

SELECT 
  BUDGETCODE,
  STATUSCODE,
  LOCKEDDATETIME
FROM BUDGETHEADER
WHERE BUDGETCODE = 'BUD_CLOSE_TEST';

SELECT '✓ All tests completed!' AS STATUS;

-- =====================================================
-- Expected Results:
-- 
-- TEST 1: ✓ Period closed successfully
-- TEST 2: ✓ Returns VALIDATION_FAILED (already closed)
-- TEST 3: ✓ Force re-close works, user updated to 200
-- TEST 4: ✓ Returns VALIDATION_FAILED (invalid period)
-- =====================================================