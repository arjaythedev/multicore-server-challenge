package conduit.adapters.inbound.http.article.handlers;

import conduit.errors.InvalidInput;

final class ArticlePagination {

    record PageRequest(
        int limit,
        long offset
    ) {
    }

    static PageRequest parse(String rawLimit, String rawOffset) {
        String limit = digits(rawLimit == null ? "20" : rawLimit);
        if (limit == null || exceeds(limit, "2147483647")) {
            throw invalid();
        }
        String offset = digits(rawOffset == null ? "0" : rawOffset);
        if (offset == null || exceeds(offset, "9223372036854775807")) {
            throw invalid();
        }
        return new PageRequest(Integer.parseInt(limit), Long.parseLong(offset));
    }

    private static String digits(String raw) {
        if (raw == null || !raw.matches("[0-9]+")) {
            return null;
        }
        return raw.replaceFirst("^0+(?!$)", "");
    }

    private static boolean exceeds(String value, String maximum) {
        return value.length() > maximum.length()
            || value.length() == maximum.length() && value.compareTo(maximum) > 0;
    }

    private static InvalidInput invalid() {
        return new InvalidInput("Invalid pagination");
    }

    private ArticlePagination() {
    }
}
