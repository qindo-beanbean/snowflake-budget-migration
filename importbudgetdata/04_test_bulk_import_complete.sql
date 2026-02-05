-- =====================================================
-- File: 04_test_bulk_import_complete.sql
-- Description: End-to-end tests for Bulk Import procedure (multiple scenarios)
-- Prerequisites:
--   - 01_schema_setup.sql and 02_test_data.sql have been executed
--   - Session variable $TARGET_BUDGET_ID is already set
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- Part 1: TEST CASE 1 - Successful Import
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 1: SUCCESSFUL IMPORT' AS INFO;
SELECT '========================================' AS INFO;

-- Clean up any existing data
TRUNCATE TABLE BUDGETIMPORT_STAGE;
DELETE FROM BUDGETLINEITEM WHERE BUDGETHEADERID = $TARGET_BUDGET_ID;

-- Insert valid test records
INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('4000', 'CC001', 2024, 1, 100.00, 10.00, 'MANUAL', 'Test record 1'),
  ('4000', 'CC002', 2024, 1, 200.00, 0,      'MANUAL', 'Test record 2'),
  ('5000', 'CC001', 2024, 1, 300.00, 50.00, 'MANUAL', 'Test record 3');

SELECT 'Staging data loaded: ' || COUNT(*) || ' rows' AS STATUS FROM BUDGETIMPORT_STAGE;

-- Execute import
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'
);

-- Verify results
SELECT 'Imported records:' AS INFO;
SELECT 
  bli.BUDGETLINEITEMID,
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  fp.PERIODNAME,
  bli.ORIGINALAMOUNT,
  bli.ADJUSTEDAMOUNT
FROM BUDGETLINEITEM bli
JOIN GLACCOUNT ga   ON bli.GLACCOUNTID   = ga.GLACCOUNTID
JOIN COSTCENTER cc  ON bli.COSTCENTERID  = cc.COSTCENTERID
JOIN FISCALPERIOD fp ON bli.FISCALPERIODID = fp.FISCALPERIODID
WHERE bli.BUDGETHEADERID = $TARGET_BUDGET_ID
  AND bli.SOURCESYSTEM = 'BULK_IMPORT'
ORDER BY bli.BUDGETLINEITEMID;

-- Expectation: 3 rows imported, 0 rejected

-- =====================================================
-- Part 2: TEST CASE 2 - Duplicate Rejection
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 2: DUPLICATE REJECTION' AS INFO;
SELECT '========================================' AS INFO;

-- Import the same data again (should all be treated as duplicates)
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'  -- Duplicates should be rejected
);

-- =====================================================
-- Part 3: TEST CASE 3 - Skip Duplicates
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 3: SKIP DUPLICATES' AS INFO;
SELECT '========================================' AS INFO;

-- Add one more new record into staging
INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('5000', 'CC002', 2024, 2, 400.00, 0, 'MANUAL', 'New record - should be imported');

SELECT 'Staging data now has: ' || COUNT(*) || ' rows' AS STATUS FROM BUDGETIMPORT_STAGE;

-- Import again with SKIP mode so only new records are inserted
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'SKIP'  -- Skip duplicates, import only new records
);

-- Check total number of BULK_IMPORT records
SELECT 'Total BULK_IMPORT records: ' || COUNT(*) AS STATUS
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $TARGET_BUDGET_ID
  AND SOURCESYSTEM = 'BULK_IMPORT';

-- =====================================================
-- Part 4: TEST CASE 4 - Validation Errors
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 4: VALIDATION ERRORS' AS INFO;
SELECT '========================================' AS INFO;

TRUNCATE TABLE BUDGETIMPORT_STAGE;

INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('9999', 'CC001',    2024, 1, 100.00, 0, 'MANUAL', 'Invalid account'),
  ('4000', 'INVALID',  2024, 1, 200.00, 0, 'MANUAL', 'Invalid cost center'),
  ('4000', 'CC001',    2099, 99, 300.00, 0, 'MANUAL', 'Invalid period'),
  ('4000', 'CC001',    2024, 1, NULL,   0, 'MANUAL', 'Missing amount');

SELECT 'Staging data loaded: ' || COUNT(*) || ' invalid rows' AS STATUS FROM BUDGETIMPORT_STAGE;

DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'
);

-- Inspect rows that failed validation
SELECT 'Validation errors:' AS INFO;
SELECT 
  ROWID,
  ACCOUNTNUMBER,
  COSTCENTERCODE,
  FISCALYEAR,
  FISCALMONTH,
  ORIGINALAMOUNT,
  VALIDATIONERRORS
FROM IMPORTSTAGING_TEMP
WHERE ISVALID = FALSE
ORDER BY ROWID;

-- =====================================================
-- Part 5: TEST CASE 5 - No Validation Mode
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 5: NO VALIDATION MODE' AS INFO;
SELECT '========================================' AS INFO;

DELETE FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = $TARGET_BUDGET_ID 
  AND SOURCESYSTEM = 'BULK_IMPORT';

TRUNCATE TABLE BUDGETIMPORT_STAGE;

INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('4000', 'CC001', 2024, 1, 500.00, 0, 'MANUAL', 'No validation test');

DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'NONE',   -- Disable validation
  'REJECT'
);

-- =====================================================
-- Part 6: TEST CASE 6 - Invalid Source Type
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 6: INVALID SOURCE TYPE' AS INFO;
SELECT '========================================' AS INFO;

CALL USP_BULKIMPORTBUDGETDATA_SF(
  'INVALID_SOURCE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'
);

-- =====================================================
-- Final summary
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  FINAL SUMMARY REPORT' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  'Total imported records: ' || COUNT(*) AS SUMMARY
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $TARGET_BUDGET_ID
  AND SOURCESYSTEM = 'BULK_IMPORT';

SELECT 
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  fp.PERIODNAME,
  COUNT(*)                    AS RECORD_COUNT,
  SUM(bli.ORIGINALAMOUNT)     AS TOTAL_ORIGINAL,
  SUM(bli.ADJUSTEDAMOUNT)     AS TOTAL_ADJUSTED
FROM BUDGETLINEITEM bli
JOIN GLACCOUNT ga   ON bli.GLACCOUNTID   = ga.GLACCOUNTID
JOIN COSTCENTER cc  ON bli.COSTCENTERID  = cc.COSTCENTERID
JOIN FISCALPERIOD fp ON bli.FISCALPERIODID = fp.FISCALPERIODID
WHERE bli.BUDGETHEADERID = $TARGET_BUDGET_ID
  AND bli.SOURCESYSTEM = 'BULK_IMPORT'
GROUP BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE, fp.PERIODNAME
ORDER BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE;

SELECT '✓ All bulk import tests completed!' AS STATUS;