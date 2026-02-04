-- =====================================================
-- File: 02_test_data.sql
-- Description: Test Data for Budget Consolidation
-- Purpose: Insert sample data for testing the stored procedure
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- Clean up existing test data (optional)
-- =====================================================
-- DELETE FROM BUDGETLINEITEM WHERE BUDGETHEADERID IN (1, 101, 102);
-- DELETE FROM BUDGETHEADER WHERE BUDGETHEADERID IN (1, 101, 102);
-- DELETE FROM FISCALPERIOD WHERE FISCALPERIODID = 1;

-- =====================================================
-- 1. Insert Fiscal Period
-- =====================================================
INSERT INTO FISCALPERIOD (
  FISCALYEAR, FISCALQUARTER, FISCALMONTH,
  PERIODNAME, PERIODSTARTDATE, PERIODENDDATE,
  ISCLOSED
)
VALUES (2024, 1, 1, '2024-01', '2024-01-01', '2024-01-31', FALSE)
RETURNING FISCALPERIODID;

-- Note: Record the returned FISCALPERIODID (should be 1)

-- =====================================================
-- 2. Insert Budget Header (Source Budget)
-- =====================================================
INSERT INTO BUDGETHEADER (
  BUDGETCODE, BUDGETNAME, BUDGETTYPE, SCENARIOTYPE,
  FISCALYEAR, STARTPERIODID, ENDPERIODID,
  BASEBUDGETHEADERID, STATUSCODE, VERSIONNUMBER,
  EXTENDEDPROPERTIES
)
VALUES (
  'BUD_2024_Q1',
  '2024 Q1 Budget',
  'OPERATIONAL',
  'BASELINE',
  2024,
  1,  -- FISCALPERIODID from above
  1,
  NULL,
  'APPROVED',  -- Must be APPROVED or LOCKED for consolidation
  1,
  OBJECT_CONSTRUCT('Department', 'Sales', 'Region', 'East')
)
RETURNING BUDGETHEADERID;

-- Note: Record the returned BUDGETHEADERID (should be 1)

-- =====================================================
-- 3. Insert Budget Line Items (Test Data)
-- =====================================================

-- Line Item 1: Salary - Sales Dept - Jan 2024
INSERT INTO BUDGETLINEITEM (
  BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
  SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
  LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
)
VALUES (
  1,      -- BUDGETHEADERID
  1001,   -- GLACCOUNTID (Salary account)
  2001,   -- COSTCENTERID (Sales department)
  1,      -- FISCALPERIODID (2024-01)
  100000, -- ORIGINALAMOUNT
  5000,   -- ADJUSTEDAMOUNT
  'MANUAL',
  'TEST',
  'TEST_DATA_1',
  FALSE,
  1,
  CURRENT_TIMESTAMP()
);

-- Line Item 2: Salary - Sales Dept - Jan 2024 (Another entry, will be consolidated)
INSERT INTO BUDGETLINEITEM (
  BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
  SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
  LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
)
VALUES (
  1,      -- BUDGETHEADERID
  1001,   -- GLACCOUNTID (Same as above)
  2001,   -- COSTCENTERID (Same as above)
  1,      -- FISCALPERIODID (Same as above)
  50000,  -- ORIGINALAMOUNT
  0,      -- ADJUSTEDAMOUNT
  'MANUAL',
  'TEST',
  'TEST_DATA_2',
  FALSE,
  1,
  CURRENT_TIMESTAMP()
);

-- Line Item 3: Salary - R&D Dept - Jan 2024
INSERT INTO BUDGETLINEITEM (
  BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
  SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
  LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
)
VALUES (
  1,      -- BUDGETHEADERID
  1001,   -- GLACCOUNTID (Salary account)
  2002,   -- COSTCENTERID (R&D department - different from above)
  1,      -- FISCALPERIODID (2024-01)
  200000, -- ORIGINALAMOUNT
  10000,  -- ADJUSTEDAMOUNT
  'MANUAL',
  'TEST',
  'TEST_DATA_3',
  FALSE,
  1,
  CURRENT_TIMESTAMP()
);

-- Line Item 4: Rent - Sales Dept - Jan 2024
INSERT INTO BUDGETLINEITEM (
  BUDGETHEADERID, GLACCOUNTID, COSTCENTERID, FISCALPERIODID,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE,
  SOURCESYSTEM, SOURCEREFERENCE, ISALLOCATED,
  LASTMODIFIEDBYUSERID, LASTMODIFIEDDATETIME
)
VALUES (
  1,      -- BUDGETHEADERID
  1002,   -- GLACCOUNTID (Rent account - different from above)
  2001,   -- COSTCENTERID (Sales department)
  1,      -- FISCALPERIODID (2024-01)
  30000,  -- ORIGINALAMOUNT
  0,      -- ADJUSTEDAMOUNT
  'MANUAL',
  'TEST',
  'TEST_DATA_4',
  FALSE,
  1,
  CURRENT_TIMESTAMP()
);

-- =====================================================
-- 4. Verify Test Data
-- =====================================================
SELECT 'Test data inserted successfully!' AS STATUS;

-- Check Budget Header
SELECT 
  BUDGETHEADERID,
  BUDGETCODE,
  BUDGETNAME,
  STATUSCODE,
  FISCALYEAR
FROM BUDGETHEADER 
WHERE BUDGETHEADERID = 1;

-- Check Budget Line Items (should have 4 rows)
SELECT 
  BUDGETLINEITEMID,
  GLACCOUNTID,
  COSTCENTERID,
  FISCALPERIODID,
  ORIGINALAMOUNT,
  ADJUSTEDAMOUNT,
  ORIGINALAMOUNT + ADJUSTEDAMOUNT AS TOTALAMOUNT
FROM BUDGETLINEITEM 
WHERE BUDGETHEADERID = 1
ORDER BY GLACCOUNTID, COSTCENTERID;

-- Expected consolidation result:
-- After running the procedure, we should have 3 consolidated rows:
-- 1. GL:1001, CC:2001, Period:1 -> 155,000 (100K+5K + 50K+0)
-- 2. GL:1001, CC:2002, Period:1 -> 210,000 (200K+10K)
-- 3. GL:1002, CC:2001, Period:1 -> 30,000  (30K+0)
