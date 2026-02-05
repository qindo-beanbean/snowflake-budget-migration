-- =====================================================
-- File: 04_test_execute_cost_allocation.sql
-- Purpose: 基础验证 USP_EXECUTECOSTALLOCATION_SF 存储过程
-- 前置条件:
--   1) 已执行 schema/test_data 脚本，库里至少有一个 BUDGETHEADER
--   2) 已创建过程 USP_EXECUTECOSTALLOCATION_SF
--   3) （可选）AllocationRule 尚未配置时，本测试主要验证过程能安全返回
-- =====================================================

USE DATABASE PLANNING_DB;
USE SCHEMA PLANNING;

-- 选一个现有的 BudgetHeader 作为测试对象
SET TEST_BUDGET_ID = (
  SELECT MIN(BUDGETHEADERID)
  FROM BUDGETHEADER
);

SELECT 'Test BudgetHeaderID = ' || $TEST_BUDGET_ID AS INFO;

-- 看一下 AllocationRule 当前情况
SELECT COUNT(*) AS ACTIVE_RULE_COUNT
FROM ALLOCATIONRULE
WHERE ISACTIVE = TRUE
  AND EFFECTIVEFROMDATE <= CURRENT_DATE()
  AND (EFFECTIVETODATE IS NULL OR EFFECTIVETODATE >= CURRENT_DATE());

-- =====================================================
-- Test Case 1: Dry run, 无激活规则的情况
-- 预期: ROWSALLOCATED = 0, WARNINGMESSAGES 提示无规则
-- =====================================================

CALL USP_EXECUTECOSTALLOCATION_SF(
  BUDGETHEADERID  => $TEST_BUDGET_ID,
  FISCALPERIODID  => NULL,
  DRYRUN          => TRUE,
  ROWSALLOCATED   => NULL,
  WARNINGMESSAGES => NULL
);

-- 结果会显示:
--  - ROWSALLOCATED: 0
--  - WARNINGMESSAGES: 'No active allocation rules ...'（如果当前没有配置规则）

-- =====================================================
-- Test Case 2: 非 Dry run（即使没有规则，也应安全返回）
-- =====================================================

CALL USP_EXECUTECOSTALLOCATION_SF(
  BUDGETHEADERID  => $TEST_BUDGET_ID,
  FISCALPERIODID  => NULL,
  DRYRUN          => FALSE,
  ROWSALLOCATED   => NULL,
  WARNINGMESSAGES => NULL
);

-- 预期:
--  - 过程成功返回，不报错
--  - 在没有规则的情况下 ROWSALLOCATED 仍为 0，不对 BUDGETLINEITEM 产生修改

-- =====================================================
-- 验证：确认没有产生意外分摊行（可选）
-- =====================================================

SELECT 
  BUDGETHEADERID,
  COUNT(*) AS LINE_COUNT
FROM BUDGETLINEITEM
WHERE BUDGETHEADERID = $TEST_BUDGET_ID
GROUP BY BUDGETHEADERID;