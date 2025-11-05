# pt-osc-incremental-update-plugin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Perl plugin for Percona Toolkit's `pt-online-schema-change` that allows you to execute custom SQL update statements **incrementally in batches** on the new table during an online schema change process (e.g., while adding an index).

This is particularly useful for scenarios like data backfilling or data cleansing concurrently with a data migration.

[中文版本](./README.md)

---

## ✨ Features

- **Incremental Updates**: The plugin executes your SQL after each data chunk is copied, ensuring that only newly copied rows are processed, thus avoiding full table scans.
- **Custom SQL**: You can provide any complex update logic through a temporary SQL file.
- **Atomic Operation**: Binds the data update logic with the schema change in a single `pt-online-schema-change` command, simplifying the workflow and ensuring data consistency.
- **Safety Checks**: The plugin validates the existence and format of the SQL file and automatically deletes it after use for security.
- **Compatibility**: Leverages the standard hook mechanism of `pt-online-schema-change`.

## ⚙️ How It Works

The plugin hooks into several key execution points of `pt-online-schema-change`:

1.  **`new` (Initialization)**:
    *   On startup, the plugin reads the SQL statement from `/tmp/pt_osc_update_rows.sql`.
    *   It validates the SQL format (must contain the placeholder `%new_table% t`).
    *   The SQL is stored in memory, and the temporary file is immediately deleted.

2.  **`after_create_new_table` (After New Table Creation)**:
    *   This hook is triggered after `pt-online-schema-change` creates the empty temporary table with the new schema.
    *   The plugin captures and saves the actual name of this new table.

3.  **`on_copy_rows_after_nibble` (After Row Copy)**:
    *   `pt-online-schema-change` copies data from the old table to the new one in chunks (nibbles). This hook is fired after each chunk is copied.
    *   The plugin performs the following actions:
        1.  Retrieves the table's primary key information (only single-column PKs are supported).
        2.  Replaces the `%new_table%` placeholder in the SQL template with the actual new table name.
        3.  Dynamically appends a `WHERE` clause (e.g., `AND t.primary_key > last_pk_value`) to ensure only the most recently copied rows are updated.
        4.  Executes the constructed SQL statement.
        5.  Records the maximum primary key value processed so far, to be used in the next incremental update.

## 🚀 How to Use

#### 1. Deploy the Plugin Script

Place the `plugin-pt-osc-update-rows.pl` script in a directory accessible by `pt-online-schema-change`. If you are using Docker, you can mount the directory as follows:

```bash
# Example: Mount a local plugin directory to /opt/plugin-perls in the container
docker run -it --rm \
  -v /path/to/your/plugins:/opt/plugin-perls \
  registry.cn-hangzhou.aliyuncs.com/flyhand/perconalab-toolkit:3.7.0 bash```

#### 2. Prepare the Custom SQL File

Create a temporary SQL file at `/tmp/pt_osc_update_rows.sql`. **You must adhere to the following rules**:

- Use `%new_table%` as the placeholder for the new table name.
- You must alias the new table as `t`, e.g., `%new_table% t`.

**Example SQL file content:**

```bash
# Suppose we want to backfill the enterprise_id column in the new table
# based on data from the 'cart' and 'restaurant' tables.
echo "UPDATE %new_table% t
LEFT JOIN cart c ON c.id = t.cart_id
LEFT JOIN restaurant r ON r.id = c.restaurant_id
SET t.enterprise_id = r.enterprise_id
WHERE t.enterprise_id = 0" > /tmp/pt_osc_update_rows.sql
```

#### 3. Execute pt-online-schema-change

When invoking the `pt-online-schema-change` command, specify the plugin using the `--plugin` argument.

```bash
/usr/bin/pt-online-schema-change \
  --alter "ADD INDEX idx_enterprise_id(enterprise_id)" \
  --plugin /opt/plugin-perls/plugin-pt-osc-update-rows.pl \
  --preserve-triggers \
  --chunk-size=1000 \
  --execute \
  h=127.0.0.1,P=3306,u=root,p="PASSWORD",D=DATABASE_NAME,t=TABLE_NAME
```

## ⚠️ Important Notes

- **SQL File Path**: The plugin is hardcoded to read from `/tmp/pt_osc_update_rows.sql`. Ensure the path is correct and that you have the necessary read/write permissions.
- **SQL Alias**: Your update statement must use `t` as the alias for the new table (e.g., `UPDATE %new_table% t ...`).
- **Primary Key Limitation**: The incremental update logic of this plugin only supports **single-column primary keys**. Composite primary keys are not supported.
- **Temporary File**: The plugin will **immediately and automatically delete** `/tmp/pt_osc_update_rows.sql` after successfully reading its content.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
