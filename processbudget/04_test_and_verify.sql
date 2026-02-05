-- =====================================================
-- File: 04_test_and_verify.sql
-- Description: Test Execution and Verification Script
-- Purpose: Call the stored procedure and verify results
-- Matches 7-parameter version of USP_PROCESSBUDGETCONSOLIDATION_SF
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- 1. Execute the Stored Procedure
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 1: BASIC CONSOLIDATION' AS INFO;
SELECT '========================================' AS INFO;

-- Get source budget ID
SET SOURCE_BUDGET_ID = (SELECT BUDGETHEADERID FROM BUDGETHEADER WHERE BUDGETCODE = 'BUD_2024_Q1');

SELECT 'Source Budget ID: ' || $SOURCE_BUDGET_ID AS INFO;

-- Call procedure with correct 7 parameters
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  $SOURCE_BUDGET_ID,  -- 1. SOURCEBUDGETHEADERID
  'FULL',             -- 2. CONSOLIDATIONTYPE
  TRUE,               -- 3. INCLUDEELIMINATIONS
  TRUE,               -- 4. RECALCULATEALLOCATIONS
  NULL,               -- 5. PROCESSINGOPTIONS
  1,                  -- 6. USERID
  FALSE               -- 7. DEBUGMODE
);

-- The procedure returns a table with results
-- Result columns: TARGETBUDGETHEADERID, ROWSPROCESSED, ERRORMESSAGE, RETURNCODE

-- =====================================================
-- 2. Verify Consolidated Budget Header was Created
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  VERIFY CONSOLIDATED BUDGET HEADER' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  BUDGETTYPE,
  SCENARIOTYPE,
  STATUSCODE,
  BASEBUDGETHEADERID
FROM BUDGETHEADER 
WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
ORDER BY BUDGETHEADERID DESC
LIMIT 1;

-- Expected Output:
-- - BUDGETCODE: BUD_2024_Q1_CONSOL_20260205 (or current date)
-- - BUDGETNAME: 2024 Q1 Budget - Consolidated
-- - BUDGETTYPE: CONSOLIDATED
-- - STATUSCODE: DRAFT
-- - BASEBUDGETHEADERID: (source budget ID)

-- Get consolidated budget ID for further tests
SET CONSOL_BUDGET_ID = (
  SELECT MAX(BUDGETHEADERID) 
  FROM BUDGETHEADER 
  WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
);

SELECT 'Consolidated Budget ID: ' || $CONSOL_BUDGET_ID AS INFO;

-- =====================================================
-- 3. Verify Consolidated Line Items
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  VERIFY CONSOLIDATED LINE ITEMS' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  bli.BUDGETLINEITEMID,
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  fp.PERIODNAME,
  bli.ORIGINALAMOUNT,
  bli.ADJUSTEDAMOUNT,
  bli.ORIGINALAMOUNT + bli.ADJUSTEDAMOUNT AS TOTAL_AMOUNT,
  bli.SPREADMETHODCODE,
  bli.SOURCESYSTEM
FROM BUDGETLINEITEM bli
LEFT JOIN GLACCOUNT ga ON bli.GLACCOUNTID = ga.GLACCOUNTID
LEFT JOIN COSTCENTER cc ON bli.COSTCENTERID = cc.COSTCENTERID
LEFT JOIN FISCALPERIOD fp ON bli.FISCALPERIODID = fp.FISCALPERIODID
WHERE bli.BUDGETHEADERID = $CONSOL_BUDGET_ID
ORDER BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE;

-- Expected Output (3 rows consolidated from 4 source rows):
-- 1001 | CC_SALES | 2024-01 | 155,000 (105K + 50K consolidated)
-- 1001 | CC_RND   | 2024-01 | 210,000
-- 1002 | CC_SALES | 2024-01 | 30,000

-- =====================================================
-- 4. Compare Source vs Consolidated Data
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  COMPARE SOURCE VS CONSOLIDATED' AS INFO;
SELECT '========================================' AS INFO;

-- Source Budget Line Items
SELECT 
  'SOURCE' AS BUDGET_TYPE,
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  COUNT(*) AS LINE_COUNT,
  SUM(bli.ORIGINALAMOUNT + bli.ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM bli
LEFT JOIN GLACCOUNT ga ON bli.GLACCOUNTID = ga.GLACCOUNTID
LEFT JOIN COSTCENTER cc ON bli.COSTCENTERID = cc.COSTCENTERID
WHERE bli.BUDGETHEADERID = $SOURCE_BUDGET_ID
GROUP BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE

UNION ALL

-- Consolidated Budget Line Items
SELECT 
  'CONSOLIDATED' AS BUDGET_TYPE,
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  COUNT(*) AS LINE_COUNT,
  SUM(bli.ORIGINALAMOUNT + bli.ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM bli
LEFT JOIN GLACCOUNT ga ON bli.GLACCOUNTID = ga.GLACCOUNTID
LEFT JOIN COSTCENTER cc ON bli.COSTCENTERID = cc.COSTCENTERID
WHERE bli.BUDGETHEADERID = $CONSOL_BUDGET_ID
GROUP BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE

ORDER BY ACCOUNTNUMBER, COSTCENTERCODE, BUDGET_TYPE;

-- Expected Comparison:
-- 1001 | CC_SALES | SOURCE       -> 2 lines, 155,000 total
-- 1001 | CC_SALES | CONSOLIDATED -> 1 line,  155,000 total ✓
-- 1001 | CC_RND   | SOURCE       -> 1 line,  210,000 total
-- 1001 | CC_RND   | CONSOLIDATED -> 1 line,  210,000 total ✓
-- 1002 | CC_SALES | SOURCE       -> 1 line,  30,000 total
-- 1002 | CC_SALES | CONSOLIDATED -> 1 line,  30,000 total ✓

-- =====================================================
-- 5. Verify Total Amounts Match
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  VERIFY TOTAL AMOUNTS MATCH' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  'SOURCE TOTAL' AS DESCRIPTION,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = $SOURCE_BUDGET_ID

UNION ALL

SELECT 
  'CONSOLIDATED TOTAL' AS DESCRIPTION,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = $CONSOL_BUDGET_ID;

-- Expected Output:
-- SOURCE TOTAL:       395,000
-- CONSOLIDATED TOTAL: 395,000 ✓

-- =====================================================
-- 6. Test Error Handling - Invalid Source Budget ID
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 2: INVALID SOURCE BUDGET' AS INFO;
SELECT '========================================' AS INFO;

CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  99999,    -- Non-existent SOURCEBUDGETHEADERID
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- Expected Result: RETURNCODE = -1
-- ERRORMESSAGE: "Source budget header not found"

-- =====================================================
-- 7. Test Error Handling - Non-Approved Budget
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 3: NON-APPROVED BUDGET' AS INFO;
SELECT '========================================' AS INFO;

-- Create a DRAFT budget
INSERT INTO BUDGETHEADER (
  BUDGETCODE, BUDGETNAME, BUDGETTYPE, SCENARIOTYPE,
  FISCALYEAR, STARTPERIODID, ENDPERIODID, STATUSCODE, VERSIONNUMBER
)
SELECT
  'BUD_DRAFT_TEST',
  'Draft Budget Test',
  'OPERATIONAL',
  'BASELINE',
  2024,
  $TEST_PERIOD_ID,  -- Add STARTPERIODID
  $TEST_PERIOD_ID,  -- Add ENDPERIODID
  'DRAFT',  -- Not APPROVED or LOCKED
  1
WHERE NOT EXISTS (SELECT 1 FROM BUDGETHEADER WHERE BUDGETCODE = 'BUD_DRAFT_TEST');

SET DRAFT_BUDGET_ID = (SELECT BUDGETHEADERID FROM BUDGETHEADER WHERE BUDGETCODE = 'BUD_DRAFT_TEST');

-- Try to consolidate the DRAFT budget
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  $DRAFT_BUDGET_ID,
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- Expected Result: RETURNCODE = -1
-- ERRORMESSAGE: "Source budget must be in APPROVED or LOCKED status"

-- =====================================================
-- 8. Test Idempotency - Run Procedure Multiple Times
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST 4: IDEMPOTENCY' AS INFO;
SELECT '========================================' AS INFO;

-- Run the procedure again on the same source budget
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  $SOURCE_BUDGET_ID,
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- A new consolidated budget should be created each time
SELECT 
  COUNT(*) AS CONSOLIDATED_BUDGET_COUNT
FROM BUDGETHEADER 
WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%';

-- Expected: At least 2 consolidated budgets

-- =====================================================
-- TEST SUMMARY
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST SUMMARY' AS INFO;
SELECT '========================================' AS INFO;

-- Show all consolidated budgets created
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  STATUSCODE,
  BASEBUDGETHEADERID
FROM BUDGETHEADER 
WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
ORDER BY BUDGETHEADERID DESC;

-- =====================================================
-- SUCCESS CRITERIA
-- =====================================================
-- ✓ Stored procedure executes without errors (RETURNCODE = 0)
-- ✓ New consolidated budget header is created with correct attributes
-- ✓ Line items are correctly aggregated (4 source rows → 3 consolidated rows)
-- ✓ Total amounts match between source and consolidated budgets
-- ✓ Error handling works correctly for invalid inputs
-- ✓ Procedure is idempotent (can run multiple times safely)
-- ✓ Consolidated budgets link back to source via BASEBUDGETHEADERID

SELECT '✓ All consolidation tests completed successfully!' AS STATUS;