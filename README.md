## Snowflake Budget Migration

This repository contains a set of stored procedures and test scripts migrated from **SQL Server** to **Snowflake**.  
The solution covers end‑to‑end FP&A workflows: budget data import, consolidation, cost allocation, rolling forecast generation, intercompany balance reconciliation, and financial close orchestration.

---

### Project Structure

- **importbudgetdata/**  
  - **Purpose**: Bulk import budget data from a staging table into the canonical budget tables, including validation and duplicate handling.  
  - **Core procedure**: `USP_BULKIMPORTBUDGETDATA_SF`

- **processbudget/**  
  - **Purpose**: Consolidate budget line items into a new “consolidated” budget version (by GL account, cost center, fiscal period).  
  - **Core procedure**: `USP_PROCESSBUDGETCONSOLIDATION_SF`

- **executeallocation/**  
  - **Purpose**: Execute cost allocation rules and distribute expenses across target cost centers / GL accounts.  
  - **Core procedure**: `USP_EXECUTECOSTALLOCATION_SF`

- **generateforecast/**  
  - **Purpose**: Build a rolling forecast based on N months of historical data and configurable forecast methods.  
  - **Core procedure**: `USP_GENERATEROLLINGFORECAST_SF`

- **reconcilebalance/**  
  - **Purpose**: Reconcile intercompany balances by entity pair and GL account, with tolerance thresholds and optional auto‑adjustments.  
  - **Core procedure**: `USP_RECONCILEINTERCOMPANYBALANCES_SF`

- **financialclose/**  
  - **Purpose**: Perform financial period close (SOFT / HARD / FINAL), optionally chaining consolidation, allocation, and reconciliation steps.  
  - **Core procedure**: `USP_PERFORMFINANCIALCLOSE_SF`

- **run_all_sql.py**  
  - **Purpose**: Helper script that executes all `.sql` files in order (schema → test data → procedures → tests) to fully deploy and validate the solution in Snowflake.

Naming conventions inside each module:

- `01_*.sql` – schema / setup scripts  
- `02_*.sql` – test data  
- `03_usp_*.sql` – core stored procedures  
- `04_test_*.sql` – test and verification scripts

---

### Prerequisites (Snowflake Environment)

Create the base warehouse, database and schema (if they do not already exist):

```sql
CREATE WAREHOUSE IF NOT EXISTS WH_PLANNING
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;

CREATE DATABASE IF NOT EXISTS PLANNING_DB;
CREATE SCHEMA IF NOT EXISTS PLANNING_DB.PLANNING;
```

> Before running the scripts, ensure the current `WAREHOUSE`, `DATABASE`, and `SCHEMA` are set to an environment that can create or access these objects.

---

### One‑Click Deployment and Testing (Python)

The `run_all_sql.py` script orchestrates all SQL scripts and can recreate the full solution and test data in any Snowflake environment.

#### 1. Install dependencies

```bash
pip install "snowflake-connector-python[pandas]"
```

#### 2. Configure environment variables

In your shell, set (example):

```bash
export SNOWFLAKE_ACCOUNT='your_account'        # e.g. xy12345 or org-account
export SNOWFLAKE_USER='your_user'
export SNOWFLAKE_PASSWORD='your_password'

export SNOWFLAKE_ROLE='ACCOUNTADMIN'           # optional, default ACCOUNTADMIN
export SNOWFLAKE_WAREHOUSE='WH_PLANNING'      # optional, default WH_PLANNING
export SNOWFLAKE_DATABASE='PLANNING_DB'       # optional, default PLANNING_DB
export SNOWFLAKE_SCHEMA='PLANNING'            # optional, default PLANNING
```

> **Security note**: Do not commit files that contain plaintext passwords (e.g. your shell profile) to version control, and never hard‑code credentials into this repository.

#### 3. Run the script

From the repository root:

```bash
cd <repo-root>
python run_all_sql.py
```

The script prints the result for each SQL file and each statement, and ends with a summary such as:

- `All SQL files executed successfully!`  
- A list of successfully created procedures (all six `USP_..._SF` procedures).

Execution flow:

1. Use `processbudget/01_schema_setup.sql` to verify and/or initialize the core schema.  
2. Execute each module’s test data scripts (`02_*.sql`).  
3. Create all stored procedures from the `03_usp_*.sql` files.  
4. Run the `04_test_*.sql` scripts to validate behaviour end‑to‑end.

If any file is missing or an environment variable is not configured, `run_all_sql.py` will print a clear error message.

---

### Manual Execution (Alternative)

If you prefer running SQL manually in Snowsight, execute the scripts in this order:

1. `processbudget/01_schema_setup.sql`  
2. All `01_`–`04_` scripts under `importbudgetdata/`  
3. All `02_`–`04_` scripts under `processbudget/`  
4. `executeallocation/`, `generateforecast/`, `reconcilebalance/` – run the `03_` and `04_` scripts in each directory  
5. `financialclose/` – run `03_` and `04_`

Each `03_usp_*.sql` file typically ends with:

```sql
SHOW PROCEDURES LIKE 'USP_XXXX_SF';
```

You can use this to confirm that the corresponding procedure was created successfully.

---

### How the Procedures Were Tested

Each stored procedure has an associated test script that builds test data, invokes the procedure, and verifies the results:

- **Import**: `importbudgetdata/04_test_bulk_import_complete.sql`  
- **Budget consolidation**: `processbudget/04_test_and_verify.sql`  
- **Cost allocation**: `executeallocation/04_test_execute_cost_allocation.sql`  
- **Rolling forecast**: `generateforecast/04_test_generate_rolling_forecast.sql`  
- **Intercompany reconciliation**: `reconcilebalance/04_test_reconcile_intercompany.sql`  
- **Financial close**: `financialclose/04_test_financial_close_simple.sql`

Verification focuses on:

- **Structural correctness** – procedures compile and are created in `PLANNING_DB.PLANNING` without errors.  
- **Business correctness** – row counts, aggregated amounts, status codes / return codes and error messages match the expected scenarios.  
- **Negative paths** – invalid budget IDs, wrong status, missing rules, out‑of‑tolerance reconciliations, etc., all return appropriate error codes and messages.  
- **Idempotency** – especially for consolidation, repeated runs do not create duplicate data or inconsistent state.

The latest run of `run_all_sql.py` against account `VMB42992` completed successfully; all six procedures were created and validated via their test scripts.

---

### AI Usage Disclosure

Large Language Models (LLMs) were used as **assistive tools**, not as unchecked code generators.

- **Syntax migration** – used AI to translate SQL Server‑specific patterns to Snowflake equivalents, e.g.:  
  - OUT parameters → `RETURNS TABLE`  
  - `@@ROWCOUNT` → `SQLROWCOUNT`  
  - `IF EXISTS (SELECT ...)` → `SELECT COUNT(*) INTO ...; IF (... > 0) THEN ...`  
  - `JSON_OBJECT` → `OBJECT_CONSTRUCT`
- **Error debugging** – when Snowflake returned non‑obvious compilation errors, the error message and the relevant snippet were shared with AI to quickly locate the root cause and propose corrected syntax.  
- **Design & documentation** – AI helped refine the project layout, the design of `run_all_sql.py`, and parts of this README’s structure.

All final SQL and Python code was reviewed, executed, and validated directly in Snowflake.  
AI suggestions were treated as recommendations, not authoritative output, and were always tested and adapted before inclusion.


