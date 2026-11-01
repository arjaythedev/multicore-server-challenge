# Prints every prepared statement as "<index>\t<sql>", exactly as the server prepares them (src/sql.mojo), for the
# profiling and differential-test tools. (pg_stat_statements' copy of the text has its constants replaced by $n.)
#
#   mojo build -I src tools/print_sql.mojo -o /tmp/print_sql && /tmp/print_sql

from sql import statements


def main():
    var s = statements()
    for i in range(len(s)):
        print(String(i) + "\t" + s[i])
