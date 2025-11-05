#!/usr/bin/perl

# pt-online-schema-change 插件脚本
# 功能：在表结构变更完成后，执行自定义的SQL更新操作
# 参考文档链接：https://docs.percona.com/percona-toolkit/pt-online-schema-change.html
#
# 使用方法：
# 1. docker 启动 pt-online-schema-change 容器
#
#    正式:
#    docker run -it --rm \
#    -v /mnt/jrpy_home/perconalab-toolkit-plugin-perls:/opt/plugin-perls \
#    registry.cn-hangzhou.aliyuncs.com/flyhand/perconalab-toolkit:3.7.0 bash

# 2. 将需要执行的SQL语句写入临时文件 /tmp/pt_osc_update_rows.sql
#    SQL中使用 %new_table% 作为新表名的占位符
# 3. 调用 pt-online-schema-change 时指定此插件
#
#    调用方式如下：
#    echo "UPDATE %new_table% t
#    LEFT JOIN cart c ON c.id=t.cart_id
#    LEFT JOIN restaurant r ON r.id = c.restaurant_id
#    SET t.enterprise_id = r.enterprise_id
#    WHERE t.enterprise_id=0" > /tmp/pt_osc_update_rows.sql
#    /usr/bin/pt-online-schema-change \
#      --alter "ADD INDEX idx_enterprise_id(enterprise_id)" \
#      --plugin /opt/plugin-perls/plugin-pt-osc-update-rows.pl \
#      --preserve-triggers \
#      --chunk-size=1000 \
#      --execute \
#      h=127.0.0.1,P=3306,u=root,p="PASSWORD",D=DATABASE_NAME,t=TABLE_NAME
#
# 工作流程：
# - 在钩子构造函数new方法：读取临时文件中的SQL语句，保存到对象属性中，然后删除临时文件
# - 在钩子函数 after_create_new_table 中保存新表名
# - 在钩子函数 on_copy_rows_after_nibble：替换SQL中的占位符并执行SQL
#
# 注意事项：
# - 确保临时文件路径正确：/tmp/pt_osc_update_rows.sql
# - SQL语句必须使用小写t作为新表的别名，插件会用该别名。如：%new_table% t
# - SQL语句必须使用 %new_table% 作为新表名的占位符
# - 插件执行完成后会自动删除临时文件

package pt_online_schema_change_plugin;

use strict;

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    my $sql_file = '/tmp/pt_osc_update_rows.sql';
    if (-e $sql_file) {
        open my $fh, '<',$sql_file or die "Cannot open SQL file: $!";
        my $sql = do { local$/; <$fh> };  # 读取整个文件内容
        close $fh;

        # 检查SQL是否为空
        unless ($sql && $sql =~ /\S/) {
            die "Error: SQL file:$sql_file is empty\n";
        }
        unless ($sql =~ /%new_table% t\b/) {
            die "Error: SQL file:$sql_file does not contain '%new_table% t' as a whole word placeholder\n";
        }
        $self->{update_rows_sql} = $sql;
        unlink $sql_file;  # 删除临时文件
    } else {
        die "Error: SQL file:$sql_file not found\n";
    }
    return bless $self, $class;
}

sub after_create_new_table {
    my ($self, %args) = @_;
    $self->{new_table_name} = $args{new_tbl}->{name};
}

sub on_copy_rows_after_nibble {
    my ($self, %args) = @_;

    my $dbh =$self->{cxn}->dbh;
    unless ($self->{pk_col_name_fetched}) {
        my $index_name = 'PRIMARY';
        my $tbl = $args{tbl}->{tbl_struct};
        my $index_info = $tbl->{keys}->{$index_name};
        unless ($index_info && @{$index_info->{cols}}) {
            die "Error: Could not find column information for index '$index_name' at copy time.\n";
        }
        my $pk_cols = $index_info->{cols};

        if (scalar(@$pk_cols) > 1) {
            die "Error: The chosen chunk index '$index_name' is a composite key ("
              . join(", ", @$pk_cols) . "). This plugin's logic only "
              . "supports single-column keys.\n";
        }
        $self->{pk_col_name} = $pk_cols->[0];
        $self->{pk_col_type} = $tbl->{type_for}->{$self->{pk_col_name}};
        $self->{pk_col_name_fetched} = 1;
    }
    if ($self->{new_table_name}) {
        my $sql = $self->{update_rows_sql};
        $sql =~ s/%new_table%/$self->{new_table_name}/g;
        my $updateSql = $sql;
        if (defined $self->{last_pk_val}) {
            my $pk_val;
            if($self->{pk_col_type} =~ /int/i){
                $pk_val = $self->{last_pk_val};
            }elsif($self->{pk_col_type} =~ /char/i){
                $pk_val = "'$self->{last_pk_val}'";
            }else{
                die "Error: Unsupported PRIMARY column type: $self->{pk_col_type}\n";
            }
            $updateSql .= " AND t.$self->{pk_col_name} > $pk_val";
        }
        # print "Update Sql: $updateSql\n";
        my $update_cnt = $dbh->do($updateSql);
        $self->{last_pk_val} = ($dbh->selectrow_array("SELECT $self->{pk_col_name} FROM $self->{new_table_name} ORDER BY $self->{pk_col_name} DESC LIMIT 1"));
    } else {
        die "Error: new_table_name not found\n";
    }
}

1;
