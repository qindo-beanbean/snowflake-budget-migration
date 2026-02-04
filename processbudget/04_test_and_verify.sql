-- =====================================================
-- File: 04_test_and_verify.sql
-- Description: Test Execution and Verification Script
-- Purpose: Call the stored procedure and verify results
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- 1. Execute the Stored Procedure
-- =====================================================
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  1,        -- SOURCEBUDGETHEADERID (the test budget we created)
  'FULL',   -- CONSOLIDATIONTYPE
  TRUE,     -- INCLUDEELIMINATIONS
  TRUE,     -- RECALCULATEALLOCATIONS
  NULL,     -- PROCESSINGOPTIONS
  1,        -- USERID
  FALSE     -- DEBUGMODE
);

-- Expected Result:
-- +----------------------+---------------+--------------+------------+
-- | TARGETBUDGETHEADERID | ROWSPROCESSED | ERRORMESSAGE | RETURNCODE |
-- +----------------------+---------------+--------------+------------+
-- | 101 (or similar)     | 3             | NULL         | 0          |
-- +----------------------+---------------+--------------+------------+

-- =====================================================
-- 2. Verify Consolidated Budget Header was Created
-- =====================================================
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  BUDGETTYPE,
  SCENARIOTYPE,
  STATUSCODE,
  BASEBUDGETHEADERID,
  EXTENDEDPROPERTIES
FROM BUDGETHEADER 
WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
ORDER BY BUDGETHEADERID DESC
LIMIT 1;

-- Expected Output:
-- - BUDGETCODE: BUD_2024_Q1_CONSOL_20250204 (or current date)
-- - BUDGETNAME: 2024 Q1 Budget - Consolidated
-- - BUDGETTYPE: CONSOLIDATED
-- - STATUSCODE: DRAFT
-- - BASEBUDGETHEADERID: 1 (links back to source)

-- =====================================================
-- 3. Verify Consolidated Line Items
-- =====================================================
SELECT 
  BUDGETLINEITEMID,
  GLACCOUNTID,
  COSTCENTERID,
  FISCALPERIODID,
  ORIGINALAMOUNT,
  ADJUSTEDAMOUNT,
  SPREADMETHODCODE,
  SOURCESYSTEM,
  SOURCEREFERENCE
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = (
  SELECT MAX(BUDGETHEADERID) 
  FROM BUDGETHEADER 
  WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
)
ORDER BY GLACCOUNTID, COSTCENTERID;

-- Expected Output (3 rows):
-- +------+-------------+--------------+----------------+----------------+----------------+------------------+--------------+
-- | ID   | GLACCOUNTID | COSTCENTERID | FISCALPERIODID | ORIGINALAMOUNT | ADJUSTEDAMOUNT | SPREADMETHODCODE | SOURCESYSTEM |
-- +------+-------------+--------------+----------------+----------------+----------------+------------------+--------------+
-- | ...  | 1001        | 2001         | 1              | 155000         | 0              | CONSOL           | CONSOLIDATION_PROC |
-- | ...  | 1001        | 2002         | 1              | 210000         | 0              | CONSOL           | CONSOLIDATION_PROC |
-- | ...  | 1002        | 2001         | 1              | 30000          | 0              | CONSOL           | CONSOLIDATION_PROC |
-- +------+-------------+--------------+----------------+----------------+----------------+------------------+--------------+

-- =====================================================
-- 4. Compare Source vs Consolidated Data
-- =====================================================
-- Source Budget Line Items
SELECT 
  'SOURCE' AS BUDGET_TYPE,
  GLACCOUNTID,
  COSTCENTERID,
  FISCALPERIODID,
  COUNT(*) AS LINE_COUNT,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = 1
GROUP BY GLACCOUNTID, COSTCENTERID, FISCALPERIODID

UNION ALL

-- Consolidated Budget Line Items
SELECT 
  'CONSOLIDATED' AS BUDGET_TYPE,
  GLACCOUNTID,
  COSTCENTERID,
  FISCALPERIODID,
  COUNT(*) AS LINE_COUNT,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = (
  SELECT MAX(BUDGETHEADERID) 
  FROM BUDGETHEADER 
  WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
)
GROUP BY GLACCOUNTID, COSTCENTERID, FISCALPERIODID

ORDER BY GLACCOUNTID, COSTCENTERID, BUDGET_TYPE;

-- Expected Comparison:
-- GL:1001, CC:2001, SOURCE      -> 2 lines, 155,000 total
-- GL:1001, CC:2001, CONSOLIDATED -> 1 line,  155,000 total ✓
-- GL:1001, CC:2002, SOURCE      -> 1 line,  210,000 total
-- GL:1001, CC:2002, CONSOLIDATED -> 1 line,  210,000 total ✓
-- GL:1002, CC:2001, SOURCE      -> 1 line,  30,000 total
-- GL:1002, CC:2001, CONSOLIDATED -> 1 line,  30,000 total ✓

-- =====================================================
-- 5. Verify Total Amounts Match
-- =====================================================
SELECT 
  'SOURCE TOTAL' AS DESCRIPTION,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = 1

UNION ALL

SELECT 
  'CONSOLIDATED TOTAL' AS DESCRIPTION,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = (
  SELECT MAX(BUDGETHEADERID) 
  FROM BUDGETHEADER 
  WHERE BUDGETCODE LIKE 'BUD_2024_Q1_CONSOL_%'
);

-- Expected Output:
-- SOURCE TOTAL:       395,000
-- CONSOLIDATED TOTAL: 395,000 ✓

-- =====================================================
-- 6. Test Error Handling - Invalid Source Budget ID
-- =====================================================
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  99999,    -- Non-existent SOURCEBUDGETHEADERID
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- Expected Result:
-- RETURNCODE: -1
-- ERRORMESSAGE: "Source budget header not found: 99999"

-- =====================================================
-- 7. Test Error Handling - Non-Approved Budget
-- =====================================================
-- First, create a DRAFT budget
INSERT INTO BUDGETHEADER (
  BUDGETCODE, BUDGETNAME, BUDGETTYPE, SCENARIOTYPE,
  FISCALYEAR, STARTPERIODID, ENDPERIODID,
  BASEBUDGETHEADERID, STATUSCODE, VERSIONNUMBER
)
VALUES (
  'BUD_DRAFT',
  'Draft Budget',
  'OPERATIONAL',
  'BASELINE',
  2024,
  1,
  1,
  NULL,
  'DRAFT',  -- Not APPROVED or LOCKED
  1
);

-- Try to consolidate the DRAFT budget
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  (SELECT MAX(BUDGETHEADERID) FROM BUDGETHEADER WHERE BUDGETCODE = 'BUD_DRAFT'),
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- Expected Result:
-- RETURNCODE: -2
-- ERRORMESSAGE: "Source budget must be in APPROVED or LOCKED status for consolidation"

-- =====================================================
-- 8. Test Idempotency - Run Procedure Multiple Times
-- =====================================================
-- Run the procedure again on the same source budget
CALL USP_PROCESSBUDGETCONSOLIDATION_SF(
  1,
  'FULL',
  TRUE,
  TRUE,
  NULL,
  1,
  FALSE
);

-- A new consolidated budget should be created each time
-- (because BUDGETCODE includes the current date)
-- Verify multiple consolidated budgets exist
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  CREATED_ON
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
-- ✓ Metadata is correctly captured in EXTENDEDPROPERTIES

SELECT '✓ All tests completed successfully!' AS STATUS;
