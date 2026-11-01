package dev.moose.conduit.database;

import java.sql.Array;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;

public class DatabaseSession {

    private final DatabaseService database;
    private final Map<NumberedSql, PreparedStatement> statements = new HashMap<>();
    private Connection connection;

    public DatabaseSession(DatabaseService database) {
        this.database = database;
    }

    public ResultSet query(NumberedSql sql, Object... values) throws SQLException {
        final PreparedStatement statement = statement(sql);
        sql.bind(statement, values);
        return statement.executeQuery();
    }

    public int update(NumberedSql sql, Object... values) throws SQLException {
        final PreparedStatement statement = statement(sql);
        sql.bind(statement, values);
        return statement.executeUpdate();
    }

    public Array longs(Long[] values) throws SQLException {
        return connection().createArrayOf("int8", values);
    }

    public Array ints(Integer[] values) throws SQLException {
        return connection().createArrayOf("int4", values);
    }

    public Array texts(String[] values) throws SQLException {
        return connection().createArrayOf("text", values);
    }

    public void begin() throws SQLException {
        connection().setAutoCommit(false);
    }

    public void commit() throws SQLException {
        this.connection.commit();
        this.connection.setAutoCommit(true);
    }

    public void rollbackQuietly() {
        if (this.connection == null) {
            return;
        }
        try {
            this.connection.rollback();
            this.connection.setAutoCommit(true);
        } catch (SQLException exception) {
            reset();
        }
    }

    public void reset() {
        this.statements.clear();
        if (this.connection == null) {
            return;
        }
        try {
            this.connection.close();
        } catch (SQLException ignored) {
        }
        this.connection = null;
    }

    private PreparedStatement statement(NumberedSql sql) throws SQLException {
        final PreparedStatement cached = this.statements.get(sql);
        if (cached != null) {
            return cached;
        }
        final PreparedStatement statement = connection().prepareStatement(sql.jdbc());
        this.statements.put(sql, statement);
        return statement;
    }

    private Connection connection() throws SQLException {
        if (this.connection == null) {
            this.connection = this.database.connect();
        }
        return this.connection;
    }

}
