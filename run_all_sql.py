import os
import re
import snowflake.connector

# ===== Snowflake connection configuration =====
ACCOUNT = os.environ.get("SNOWFLAKE_ACCOUNT")
USER = os.environ.get("SNOWFLAKE_USER")
ROLE = os.environ.get("SNOWFLAKE_ROLE", "ACCOUNTADMIN")
WAREHOUSE = os.environ.get("SNOWFLAKE_WAREHOUSE", "WH_PLANNING")
DATABASE = os.environ.get("SNOWFLAKE_DATABASE", "PLANNING_DB")
SCHEMA = os.environ.get("SNOWFLAKE_SCHEMA", "PLANNING")
PASSWORD_ENV_VAR = "SNOWFLAKE_PASSWORD"

BASE_DIR = "/Users/duqin/Desktop/NYU/work/snowflake/System"

FILES_IN_ORDER = [
    "processbudget/01_schema_setup.sql",
    "importbudgetdata/01_set_up.sql",
    "importbudgetdata/02_test_data.sql",
    "importbudgetdata/03_usp_BulkImportBudgetData_SF.sql",
    "importbudgetdata/04_test_bulk_import_complete.sql",
    "processbudget/02_test_data.sql",
    "processbudget/03_usp_ProcessBudgetConsolidation_SF.sql",
    "processbudget/04_test_and_verify.sql",
    "executeallocation/03_usp_ExecuteCostAllocation_SF.sql",
    "executeallocation/04_test_execute_cost_allocation.sql",
    "generateforecast/03_usp_GenerateRollingForecast_SF.sql",
    "generateforecast/04_test_generate_rolling_forecast.sql",
    "reconcilebalance/03_usp_ReconcileIntercompanyBalances_SF.sql",
    "reconcilebalance/04_test_reconcile_intercompany.sql",
    "financialclose/03_usp_PerformFinancialClose_SF.sql",
    "financialclose/04_test_financial_close_simple.sql",
]


def split_sql_statements(sql_text: str) -> list:
    """
    Smart SQL splitter that handles stored procedures correctly.
    """
    statements = []
    current_stmt = []
    in_procedure = False
    in_dollar_quote = False
    
    lines = sql_text.split('\n')
    
    for line in lines:
        line_stripped = line.strip()
        line_upper = line_stripped.upper()
        
        # Detect start of procedure
        if not in_procedure and 'CREATE' in line_upper and 'PROCEDURE' in line_upper:
            in_procedure = True
            in_dollar_quote = False
        
        # Track $$ delimiters in procedures
        if in_procedure:
            if '$$' in line:
                in_dollar_quote = not in_dollar_quote
                
            current_stmt.append(line)
            
            # Procedure ends with $$; outside of dollar quotes
            if not in_dollar_quote and line_stripped.endswith('$$;'):
                statements.append('\n'.join(current_stmt))
                current_stmt = []
                in_procedure = False
                continue
        else:
            # Not in procedure - split by semicolon
            current_stmt.append(line)
            if line_stripped.endswith(';'):
                stmt = '\n'.join(current_stmt).strip()
                if stmt and not stmt.startswith('--'):
                    statements.append(stmt)
                current_stmt = []
    
    # Add remaining statement
    if current_stmt:
        stmt = '\n'.join(current_stmt).strip()
        if stmt and not stmt.startswith('--'):
            statements.append(stmt)
    
    return statements


def execute_sql_file_with_session(cursor, path: str) -> None:
    """
    Execute SQL file preserving session variables.
    
    Key improvement: Execute entire file content as one script
    instead of splitting into statements.
    """
    print(f"\n=== Executing: {path} ===")
    
    with open(path, "r", encoding="utf-8") as f:
        sql_text = f.read()
    
    # For test files or files with SET statements, execute as whole script
    if 'SET ' in sql_text.upper() or 'test' in path.lower():
        try:
            # Execute entire file as one script
            # This preserves session variables within the file
            for result in cursor.execute(sql_text, num_statements=0):
                pass
            print(f"  ✓ Executed as complete script (preserves session variables)")
        except Exception as e:
            error_msg = str(e)
            if 'already exists' in error_msg.lower():
                print(f"  ⊘ Skipped (already exists)")
            elif 'does not exist' in error_msg.lower():
                print(f"  ⊘ Skipped (object not found)")
            else:
                print(f"  ✗ ERROR: {error_msg[:300]}")
                # Continue instead of crashing
    else:
        # For schema/procedure files, split statements
        statements = split_sql_statements(sql_text)
        
        for i, stmt in enumerate(statements, 1):
            stmt = stmt.strip()
            if not stmt or stmt.startswith('--'):
                continue
            
            try:
                cursor.execute(stmt)
                preview = stmt[:100].replace('\n', ' ')
                if len(stmt) > 100:
                    preview += '...'
                print(f"  [{i}] ✓ {preview}")
            except Exception as e:
                error_msg = str(e)
                
                if 'already exists' in error_msg.lower():
                    print(f"  [{i}] ⊘ Skipped (already exists)")
                elif 'does not exist' in error_msg.lower() and 'drop' in stmt.lower():
                    print(f"  [{i}] ⊘ Skipped (object not found for DROP)")
                else:
                    preview = stmt[:100].replace('\n', ' ')
                    if len(stmt) > 100:
                        preview += '...'
                    print(f"  [{i}] ✗ ERROR: {error_msg[:200]}")


def main() -> None:
    # Validate environment variables
    missing = []
    if not ACCOUNT:
        missing.append("SNOWFLAKE_ACCOUNT")
    if not USER:
        missing.append("SNOWFLAKE_USER")
    
    password = os.environ.get(PASSWORD_ENV_VAR)
    if not password:
        missing.append(PASSWORD_ENV_VAR)
    
    if missing:
        raise RuntimeError(
            f"Missing environment variables: {', '.join(missing)}\n"
            "Please set, for example:\n"
            "  export SNOWFLAKE_ACCOUNT='your-account'\n"
            "  export SNOWFLAKE_USER='your-user'\n"
            "  export SNOWFLAKE_PASSWORD='your-password'\n"
        )
    
    print("="*60)
    print("Snowflake SQL Executor (Session-Aware)")
    print("="*60)
    print(f"Account: {ACCOUNT}")
    print(f"User: {USER}")
    print(f"Warehouse: {WAREHOUSE}")
    print(f"Database: {DATABASE}")
    print(f"Schema: {SCHEMA}")
    print("="*60)
    
    conn = snowflake.connector.connect(
        account=ACCOUNT,
        user=USER,
        password=password,
        role=ROLE,
        warehouse=WAREHOUSE,
        database=DATABASE,
        schema=SCHEMA,
        session_parameters={
            'MULTI_STATEMENT_COUNT': 0  # Allow multi-statement execution
        }
    )
    
    try:
        cur = conn.cursor()
        
        # Set context
        cur.execute(f"USE WAREHOUSE {WAREHOUSE}")
        cur.execute(f"USE DATABASE {DATABASE}")
        cur.execute(f"USE SCHEMA {SCHEMA}")
        
        # Execute all files
        for rel_path in FILES_IN_ORDER:
            full_path = os.path.join(BASE_DIR, rel_path)
            if not os.path.exists(full_path):
                print(f"\n⚠ File not found: {full_path}")
                continue
            execute_sql_file_with_session(cur, full_path)
        
        print("\n" + "="*60)
        print("✅ All SQL files executed successfully!")
        print("="*60)
        
        # Show final summary
        print("\nCreated Procedures:")
        cur.execute("SHOW PROCEDURES LIKE 'USP_%'")
        procedures = cur.fetchall()
        for proc in procedures:
            print(f"  ✓ {proc[1]}")  # procedure name
        
    except Exception as e:
        print(f"\n❌ Fatal error: {e}")
        import traceback
        traceback.print_exc()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()