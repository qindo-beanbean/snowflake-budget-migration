-- =====================================================
-- File: 04_test_reconcile_intercompany.sql
-- Purpose: Test USP_RECONCILEINTERCOMPANYBALANCES_SF
-- Prerequisites:
--   1) Budget header with data exists
--   2) Procedure USP_RECONCILEINTERCOMPANYBALANCES_SF created
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- 1. Select test budget
-- =====================================================

SET TEST_BUDGET_ID = (
  SELECT MIN(BUDGETHEADERID)
  FROM BUDGETHEADER
);

SELECT 'Test BudgetHeaderID = ' || $TEST_BUDGET_ID AS INFO;

-- View budget details
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  FISCALYEAR,
  STATUSCODE
FROM BUDGETHEADER
WHERE BUDGETHEADERID = $TEST_BUDGET_ID;

-- Check if budget has line items
SELECT 
  COUNT(*) AS LINE_ITEM_COUNT,
  COUNT(DISTINCT GLACCOUNTID) AS ACCOUNT_COUNT,
  COUNT(DISTINCT COSTCENTERID) AS COSTCENTER_COUNT
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $TEST_BUDGET_ID;

-- =====================================================
-- 2. Call reconciliation procedure (CORRECT SYNTAX)
-- =====================================================

-- ✅ Correct: Only 5 input parameters
CALL USP_RECONCILEINTERCOMPANYBALANCES_SF(
  $TEST_BUDGET_ID,    -- BUDGETHEADERID
  CURRENT_DATE(),     -- RECONCILIATIONDATE
  0.01,               -- TOLERANCEAMOUNT
  0.001,              -- TOLERANCEPERCENT
  FALSE               -- AUTOCREATEADJUSTMENTS
);

-- Expected return:
-- RECONCILIATIONREPORT | UNRECONCILEDCOUNT | TOTALVARIANCEAMOUNT | RETURNCODE
-- ---------------------|-------------------|---------------------|------------
-- {...}                | 0                 | 0.00                | 0

-- =====================================================
-- 3. Test with auto-create adjustments
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH AUTO-CREATE ADJUSTMENTS' AS INFO;
SELECT '========================================' AS INFO;

CALL USP_RECONCILEINTERCOMPANYBALANCES_SF(
  $TEST_BUDGET_ID,
  CURRENT_DATE(),
  0.01,
  0.001,
  TRUE                -- ✅ Auto-create adjustments
);

-- =====================================================
-- 4. Test with different tolerance settings
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH STRICT TOLERANCE' AS INFO;
SELECT '========================================' AS INFO;

-- Very strict tolerance
CALL USP_RECONCILEINTERCOMPANYBALANCES_SF(
  $TEST_BUDGET_ID,
  CURRENT_DATE(),
  0.001,              -- Only $0.001 tolerance
  0.0001,             -- 0.01% tolerance
  FALSE
);

-- =====================================================
-- 5. Test with relaxed tolerance
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH RELAXED TOLERANCE' AS INFO;
SELECT '========================================' AS INFO;

-- Relaxed tolerance
CALL USP_RECONCILEINTERCOMPANYBALANCES_SF(
  $TEST_BUDGET_ID,
  CURRENT_DATE(),
  100,                -- $100 tolerance
  0.05,               -- 5% tolerance
  FALSE
);

-- =====================================================
-- 6. Test with invalid budget ID
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH INVALID BUDGET ID' AS INFO;
SELECT '========================================' AS INFO;

CALL USP_RECONCILEINTERCOMPANYBALANCES_SF(
  99999,              -- Invalid budget ID
  CURRENT_DATE(),
  0.01,
  0.001,
  FALSE
);

-- Expected: Should return error status

-- =====================================================
-- 7. View sample results (if any intercompany data exists)
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  SAMPLE INTERCOMPANY PAIRS' AS INFO;
SELECT '========================================' AS INFO;

-- This would show pairs if they exist
-- The temp tables (ICP_PAIRS_STATUS) are session-specific
-- So we can't directly query them here after the procedure completes

-- =====================================================
-- Summary
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST SUMMARY' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  'Budget ID: ' || BUDGETHEADERID AS INFO,
  'Budget Code: ' || BUDGETCODE AS DETAIL,
  'Line Items: ' || (SELECT COUNT(*) FROM BUDGETLINEITEM WHERE BUDGETHEADERID = bh.BUDGETHEADERID) AS COUNT
FROM BUDGETHEADER bh
WHERE BUDGETHEADERID = $TEST_BUDGET_ID;

SELECT '✓ All intercompany reconciliation tests completed!' AS STATUS;

-- =====================================================
-- Expected Results Summary:
-- 
-- TEST 1 (Default tolerance, no auto-adjust):
--   ✓ Returns reconciliation report
--   ✓ Shows reconciled/unreconciled counts
--   ✓ RETURNCODE = 0
--
-- TEST 2 (With auto-create adjustments):
--   ✓ Same as test 1
--   ✓ May create adjustment entries if unreconciled pairs exist
--
-- TEST 3 (Strict tolerance):
--   ✓ More pairs may be marked as unreconciled
--
-- TEST 4 (Relaxed tolerance):
--   ✓ More pairs may be marked as reconciled
--
-- TEST 5 (Invalid budget):
--   ✓ Returns error status
--   ✓ RETURNCODE = -1
-- =====================================================

-- =====================================================
-- Notes:
-- 
-- 1. If you don't have intercompany data:
--    - All tests will return 0 pairs (which is expected)
--    - UNRECONCILEDCOUNT = 0
--    - TOTALVARIANCEAMOUNT = 0
--
-- 2. To see actual reconciliation in action:
--    - Need budget line items with matching entity codes
--    - Cost center codes should have format: "ENTITY-DEPT"
--    - Example: "US-SALES" and "CN-SALES"
--
-- 3. The simplified version doesn't require:
--    - INTERCOMPANYFLAG column in GLACCOUNT
--    - CONSOLIDATIONACCOUNTID setup
-- =====================================================