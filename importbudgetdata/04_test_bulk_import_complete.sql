-- =====================================================
-- File: 04_test_bulk_import_complete.sql
-- Description: 完整测试 Bulk Import 过程的各类场景
-- 前置条件: 已执行 01_schema_setup.sql 和 02_test_data.sql，
--           会话中已存在变量 $TARGET_BUDGET_ID
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- =====================================================
-- Part 1: TEST CASE 1 - Successful Import
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 1: SUCCESSFUL IMPORT' AS INFO;
SELECT '========================================' AS INFO;

-- 清理旧数据
TRUNCATE TABLE BUDGETIMPORT_STAGE;
DELETE FROM BUDGETLINEITEM WHERE BUDGETHEADERID = $TARGET_BUDGET_ID;

-- 插入有效测试数据
INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('4000', 'CC001', 2024, 1, 100.00, 10.00, 'MANUAL', 'Test record 1'),
  ('4000', 'CC002', 2024, 1, 200.00, 0,      'MANUAL', 'Test record 2'),
  ('5000', 'CC001', 2024, 1, 300.00, 50.00, 'MANUAL', 'Test record 3');

SELECT 'Staging data loaded: ' || COUNT(*) || ' rows' AS STATUS FROM BUDGETIMPORT_STAGE;

-- 执行导入
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'
);

-- 验证结果
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

-- 期望: 3 rows imported, 0 rejected

-- =====================================================
-- Part 2: TEST CASE 2 - Duplicate Rejection
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 2: DUPLICATE REJECTION' AS INFO;
SELECT '========================================' AS INFO;

-- 再导入同样数据（应全部被视为重复）
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'REJECT'  -- 应拒绝重复
);

-- =====================================================
-- Part 3: TEST CASE 3 - Skip Duplicates
-- =====================================================

SELECT '========================================' AS INFO;
SELECT '  TEST CASE 3: SKIP DUPLICATES' AS INFO;
SELECT '========================================' AS INFO;

-- 在 staging 中再加一条新记录
INSERT INTO BUDGETIMPORT_STAGE (
  ACCOUNTNUMBER, COSTCENTERCODE, FISCALYEAR, FISCALMONTH,
  ORIGINALAMOUNT, ADJUSTEDAMOUNT, SPREADMETHODCODE, NOTES
)
VALUES
  ('5000', 'CC002', 2024, 2, 400.00, 0, 'MANUAL', 'New record - should be imported');

SELECT 'Staging data now has: ' || COUNT(*) || ' rows' AS STATUS FROM BUDGETIMPORT_STAGE;

-- 用 SKIP 模式导入
DROP TABLE IF EXISTS IMPORTSTAGING_TEMP;
CALL USP_BULKIMPORTBUDGETDATA_SF(
  'STAGING_TABLE',
  'BUDGETIMPORT_STAGE',
  $TARGET_BUDGET_ID,
  'STRICT',
  'SKIP'  -- 跳过重复，只导入新记录
);

-- 检查总行数
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

-- 查看校验失败的行
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
  'NONE',   -- 不做校验
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
-- 最终汇总
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