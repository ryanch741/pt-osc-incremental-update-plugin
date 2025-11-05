# pt-osc-incremental-update-plugin
A Perl plugin for pt-online-schema-change to incrementally execute custom SQL updates on the new table during the row-copying process.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

一个为 Percona Toolkit 的 `pt-online-schema-change` 工具设计的 Perl 插件。它允许你在执行在线表结构变更（如添加索引）的过程中，**分批次、增量地**对新表执行自定义的 SQL 更新语句。

这对于在迁移数据的同时进行数据回填（Data Backfill）或数据清洗等场景非常有用。

[English Version](./README.en.md)

---

## ✨ 功能特性

- **增量更新**: 插件会在每个数据块 (chunk) 拷贝完成后执行 SQL，确保只对新拷贝的数据进行操作，避免全表扫描。
- **自定义 SQL**: 通过一个临时 SQL 文件，你可以传入任意复杂的更新逻辑。
- **原子性操作**: 将数据更新与表结构变更绑定在同一次 `pt-online-schema-change` 操作中，简化了流程，保证了数据一致性。
- **安全检查**: 插件会校验 SQL 文件的存在和格式，并在执行后自动删除，确保安全。
- **兼容性**: 支持 `pt-online-schema-change` 的钩子机制。

## ⚙️ 工作原理

该插件通过挂载到 `pt-online-schema-change` 的几个关键执行钩子 (Hook) 来实现其功能：

1.  **`new` (初始化)**:
    *   启动时，插件会读取 `/tmp/pt_osc_update_rows.sql` 文件中的 SQL 语句。
    *   校验 SQL 格式（必须包含占位符 `%new_table% t`）。
    *   将 SQL 存入内存，并立即删除该临时文件。

2.  **`after_create_new_table` (创建新表后)**:
    *   `pt-online-schema-change` 创建好带有新结构的临时表后，此钩子被触发。
    *   插件在此阶段获取并保存新表的真实名称。

3.  **`on_copy_rows_after_nibble` (数据拷贝后)**:
    *   `pt-online-schema-change` 将旧表数据分块拷贝到新表。每拷贝完一块，此钩子便被触发。
    *   插件会执行以下操作：
        1.  获取表的主键信息（仅支持单列主键）。
        2.  将内存中的 SQL 模板里的 `%new_table%` 替换为真实表名。
        3.  动态添加 `WHERE` 条件（例如 `AND t.primary_key > last_pk_value`），确保只更新刚刚拷贝的数据。
        4.  执行拼接好的 SQL 语句。
        5.  记录当前已处理的最大主键值，用于下一次增量更新。

## 🚀 使用方法

#### 1. 部署插件脚本

将 `plugin-pt-osc-update-rows.pl` 脚本放置到 `pt-online-schema-change` 可以访问的目录。如果你使用 Docker，可以像下面这样挂载目录：

```bash
# 示例：将本地的插件目录挂载到容器的 /opt/plugin-perls
docker run -it --rm \
  -v /path/to/your/plugins:/opt/plugin-perls \
  registry.cn-hangzhou.aliyuncs.com/flyhand/perconalab-toolkit:3.7.0 bash
```

#### 2. 准备自定义 SQL 文件

创建一个临时 SQL 文件 `/tmp/pt_osc_update_rows.sql`。**请务必遵守以下规则**：

- 使用 `%new_table%` 作为新表的占位符。
- 必须为新表指定别名 `t`，即写作 `%new_table% t`。

**示例 SQL 文件内容：**

```bash
# 假设我们要根据 cart 和 restaurant 表的数据，回填新表中的 enterprise_id 字段
echo "UPDATE %new_table% t
LEFT JOIN cart c ON c.id = t.cart_id
LEFT JOIN restaurant r ON r.id = c.restaurant_id
SET t.enterprise_id = r.enterprise_id
WHERE t.enterprise_id = 0" > /tmp/pt_osc_update_rows.sql
```

#### 3. 执行 pt-online-schema-change

在调用 `pt-online-schema-change` 命令时，通过 `--plugin` 参数指定此插件。

```bash
/usr/bin/pt-online-schema-change \
  --alter "ADD INDEX idx_enterprise_id(enterprise_id)" \
  --plugin /opt/plugin-perls/plugin-pt-osc-update-rows.pl \
  --preserve-triggers \
  --chunk-size=1000 \
  --execute \
  h=127.0.0.1,P=3306,u=root,p="PASSWORD",D=DATABASE_NAME,t=TABLE_NAME
```

## ⚠️ 注意事项

- **SQL 文件路径**: 插件硬编码读取 `/tmp/pt_osc_update_rows.sql`。请确保路径正确且有权限读写。
- **SQL 别名**: 你的更新语句中必须使用 `t` 作为新表的别名，例如 `UPDATE %new_table% t ...`。
- **主键限制**: 插件的增量更新逻辑仅支持**单列主键**。不支持复合主键。
- **临时文件**: 插件在成功读取 SQL 内容后会**立即自动删除** `/tmp/pt_osc_update_rows.sql` 文件。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
