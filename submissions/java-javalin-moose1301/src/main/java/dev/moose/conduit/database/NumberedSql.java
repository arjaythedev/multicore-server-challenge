package dev.moose.conduit.database;

import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

public class NumberedSql {

    private final String jdbc;
    private final int[] order;

    private NumberedSql(String jdbc, int[] order) {
        this.jdbc = jdbc;
        this.order = order;
    }

    public static NumberedSql of(String sql) {
        final StringBuilder builder = new StringBuilder(sql.length());
        final List<Integer> positions = new ArrayList<>();
        int sequential = 0;
        int index = 0;
        while (index < sql.length()) {
            final char character = sql.charAt(index++);
            builder.append(character);
            if (character != '?') {
                continue;
            }
            int number = -1;
            while (index < sql.length() && Character.isDigit(sql.charAt(index))) {
                number = (number < 0 ? 0 : number * 10) + (sql.charAt(index++) - '0');
            }
            positions.add(number < 0 ? sequential++ : number);
        }
        return new NumberedSql(builder.toString(), positions.stream().mapToInt(Integer::intValue).toArray());
    }

    public String jdbc() {
        return this.jdbc;
    }

    public void bind(PreparedStatement statement, Object... values) throws SQLException {
        for (int i = 0; i < this.order.length; i++) {
            statement.setObject(i + 1, values[this.order[i]]);
        }
    }

}
