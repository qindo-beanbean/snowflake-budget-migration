-- =====================================================
-- File: test_generate_rolling_forecast.sql
-- Purpose: Test USP_GENERATEROLLINGFORECAST_SF
-- Prerequisites:
--   1) Base budget header exists (BASEBUDGETHEADERID)
--   2) Historical BudgetLineItem records exist
--   3) Procedure USP_GENERATEROLLINGFORECAST_SF created
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- 1. Select base budget and verify data
-- =====================================================

SET BASE_BUDGET_ID = (
  SELECT MIN(BUDGETHEADERID)
  FROM BUDGETHEADER
);

SELECT 'Base BudgetHeaderID = ' || $BASE_BUDGET_ID AS INFO;

-- View base budget details
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  FISCALYEAR,
  STARTPERIODID,
  ENDPERIODID,
  STATUSCODE
FROM BUDGETHEADER
WHERE BUDGETHEADERID = $BASE_BUDGET_ID;

-- Check historical data
SELECT 
  COUNT(*) AS LINE_COUNT,
  MIN(FISCALPERIODID) AS MIN_PERIODID,
  MAX(FISCALPERIODID) AS MAX_PERIODID,
  SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT) AS TOTAL_AMOUNT
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $BASE_BUDGET_ID;

-- =====================================================
-- 2. Call rolling forecast procedure (CORRECT SYNTAX)
-- =====================================================

-- ✅ Correct: Only 5 input parameters
CALL USP_GENERATEROLLINGFORECAST_SF(
  $BASE_BUDGET_ID,         -- BASEBUDGETHEADERID
  12,                      -- HISTORICALPERIODS (last 12 months)
  6,                       -- FORECASTPERIODS (next 6 months)
  'WEIGHTED_AVERAGE',      -- FORECASTMETHOD
  NULL                     -- GROWTHRATEOVERRIDE (auto-calculate)
);

-- Expected return:
-- TARGETBUDGETHEADERID | FORECASTACCURACYMETRICS | RETURNCODE
-- ---------------------|-------------------------|------------
-- 205                  | {"historyPoints":...}   | 0

-- =====================================================
-- 3. View newly created forecast budget
-- =====================================================

SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  BUDGETTYPE,
  SCENARIOTYPE,
  FISCALYEAR,
  STARTPERIODID,
  ENDPERIODID,
  BASEBUDGETHEADERID,
  STATUSCODE
FROM BUDGETHEADER
WHERE BASEBUDGETHEADERID = $BASE_BUDGET_ID
  AND BUDGETCODE LIKE '%FORECAST_%'
ORDER BY BUDGETHEADERID DESC
LIMIT 5;

-- Get the forecast budget ID
SET FORECAST_BUDGET_ID = (
  SELECT MAX(BUDGETHEADERID)
  FROM BUDGETHEADER
  WHERE BASEBUDGETHEADERID = $BASE_BUDGET_ID
    AND BUDGETCODE LIKE '%FORECAST_%'
);

SELECT 'Forecast BudgetHeaderID = ' || $FORECAST_BUDGET_ID AS INFO;

-- =====================================================
-- 4. Check forecast line items
-- =====================================================

SELECT 
  bli.BUDGETLINEITEMID,
  bli.BUDGETHEADERID,
  ga.ACCOUNTNUMBER,
  cc.COSTCENTERCODE,
  fp.PERIODNAME,
  ROUND(bli.ORIGINALAMOUNT, 2) AS FORECAST_AMOUNT,
  bli.SOURCESYSTEM,
  bli.SOURCEREFERENCE
FROM BUDGETLINEITEM bli
JOIN GLACCOUNT ga ON bli.GLACCOUNTID = ga.GLACCOUNTID
JOIN COSTCENTER cc ON bli.COSTCENTERID = cc.COSTCENTERID
JOIN FISCALPERIOD fp ON bli.FISCALPERIODID = fp.FISCALPERIODID
WHERE bli.BUDGETHEADERID = $FORECAST_BUDGET_ID
ORDER BY ga.ACCOUNTNUMBER, cc.COSTCENTERCODE, fp.FISCALYEAR, fp.FISCALMONTH
LIMIT 20;

-- Summary of forecast
SELECT 
  COUNT(*) AS FORECAST_LINE_COUNT,
  COUNT(DISTINCT fp.FISCALPERIODID) AS FORECAST_PERIOD_COUNT,
  MIN(fp.PERIODNAME) AS FIRST_FORECAST_PERIOD,
  MAX(fp.PERIODNAME) AS LAST_FORECAST_PERIOD,
  ROUND(SUM(bli.ORIGINALAMOUNT), 2) AS TOTAL_FORECAST_AMOUNT
FROM BUDGETLINEITEM bli
JOIN FISCALPERIOD fp ON bli.FISCALPERIODID = fp.FISCALPERIODID
WHERE bli.BUDGETHEADERID = $FORECAST_BUDGET_ID;

-- =====================================================
-- 5. Compare historical vs forecast (optional)
-- =====================================================

-- Historical data summary
SELECT 
  'HISTORICAL' AS DATA_TYPE,
  COUNT(*) AS LINE_COUNT,
  ROUND(SUM(ORIGINALAMOUNT + ADJUSTEDAMOUNT), 2) AS TOTAL_AMOUNT,
  ROUND(AVG(ORIGINALAMOUNT + ADJUSTEDAMOUNT), 2) AS AVG_AMOUNT
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $BASE_BUDGET_ID

UNION ALL

-- Forecast data summary
SELECT 
  'FORECAST' AS DATA_TYPE,
  COUNT(*) AS LINE_COUNT,
  ROUND(SUM(ORIGINALAMOUNT), 2) AS TOTAL_AMOUNT,
  ROUND(AVG(ORIGINALAMOUNT), 2) AS AVG_AMOUNT
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $FORECAST_BUDGET_ID;

-- =====================================================
-- 6. Test with custom growth rate
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH CUSTOM GROWTH RATE' AS INFO;
SELECT '========================================' AS INFO;

-- Call with 5% growth rate override
CALL USP_GENERATEROLLINGFORECAST_SF(
  $BASE_BUDGET_ID,
  12,
  6,
  'WEIGHTED_AVERAGE',
  0.05                     -- ✅ 5% growth rate
);

-- View the new forecast
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  STATUSCODE
FROM BUDGETHEADER
WHERE BASEBUDGETHEADERID = $BASE_BUDGET_ID
  AND BUDGETCODE LIKE '%FORECAST_%'
ORDER BY BUDGETHEADERID DESC
LIMIT 2;

-- =====================================================
-- 7. Test with LINEAR_TREND method
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST WITH LINEAR TREND METHOD' AS INFO;
SELECT '========================================' AS INFO;

CALL USP_GENERATEROLLINGFORECAST_SF(
  $BASE_BUDGET_ID,
  6,                       -- Shorter history
  3,                       -- Shorter forecast
  'LINEAR_TREND',          -- ✅ Different method
  NULL
);

-- =====================================================
-- Test Summary
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST SUMMARY' AS INFO;
SELECT '========================================' AS INFO;

SELECT 
  COUNT(*) AS TOTAL_FORECAST_BUDGETS,
  MIN(BUDGETHEADERID) AS FIRST_FORECAST_ID,
  MAX(BUDGETHEADERID) AS LAST_FORECAST_ID
FROM BUDGETHEADER
WHERE BASEBUDGETHEADERID = $BASE_BUDGET_ID
  AND BUDGETCODE LIKE '%FORECAST_%';

SELECT '✓ All rolling forecast tests completed!' AS STATUS;

-- =====================================================
-- Expected Results:
-- 
-- Test 1 (WEIGHTED_AVERAGE, auto growth):
--   ✓ New budget created with BUDGETTYPE = 'ROLLING'
--   ✓ Forecast line items generated
--   ✓ RETURNCODE = 0
--
-- Test 2 (Custom 5% growth):
--   ✓ Another forecast budget created
--   ✓ Amounts reflect 5% growth
--
-- Test 3 (LINEAR_TREND):
--   ✓ Third forecast budget created
--   ✓ Different calculation method applied
-- =====================================================