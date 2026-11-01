package conduit.db;

import java.util.concurrent.CompletableFuture;

/** Runs a statement without parameters and returns its first row as strings (for startup checks). */
public final class FirstRowQuery extends PgQuery {
    private final Statement statement;
    private final CompletableFuture<String[]> result = new CompletableFuture<>();
    private String[] firstRow;

    public FirstRowQuery(Statement statement) {
        this.statement = statement;
    }

    public CompletableFuture<String[]> result() {
        return result;
    }

    @Override
    public void write(MessageWriter out) {
        out.bind(statement).execute();
        out.sync();
    }

    @Override
    public void onRow(int statementIndex, Row row) {
        if (firstRow != null) return;
        firstRow = new String[row.columnCount()];
        for (int i = 0; i < firstRow.length; i++) firstRow[i] = row.getString(i);
    }

    @Override
    public void onDone(PgError error) {
        if (error != null) result.completeExceptionally(new IllegalStateException("postgres: " + error));
        else result.complete(firstRow);
    }
}
